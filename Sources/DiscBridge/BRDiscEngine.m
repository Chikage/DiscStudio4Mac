#import "BRDiscEngine.h"
#import <DiscRecording/DiscRecording.h>
#import <DiskArbitration/DiskArbitration.h>

static NSError *BRError(NSString *message) {
    return [NSError errorWithDomain:@"app.br.discburner" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSArray<DRTrack *> *BRTracks(id layout) {
    if ([layout isKindOfClass:DRTrack.class]) return @[layout];
    if (![layout isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in layout) [tracks addObjectsFromArray:BRTracks(item)];
    return tracks;
}

@interface BRDiscEngine ()
@property (nonatomic, strong) DRNotificationCenter *center;
@property (nonatomic, strong, nullable) DRBurn *burn;
@property (nonatomic, strong, nullable) id layout;
@property (nonatomic, strong, nullable) NSURL *imageURL;
@property (nonatomic, strong, nullable) NSDictionary *imageAttributes;
@property (nonatomic) uint64_t requiredBlocks;
@property (nonatomic) NSUInteger preparationGeneration;
@property (nonatomic) BOOL cancellationRequested;
@property (nonatomic, strong, nullable) id activity;
@property (nonatomic, copy, nullable) NSString *lastDiagnosticState;
@end

@implementation BRDiscEngine

- (void)observeDevices {
    NSAssert(NSThread.isMainThread, @"Use BRDiscEngine on the main thread");
    if (self.center) return;
    self.center = [DRNotificationCenter currentRunLoopCenter];
    for (NSString *name in @[DRDeviceAppearedNotification, DRDeviceDisappearedNotification,
                             DRDeviceStatusChangedNotification]) {
        [self.center addObserver:self selector:@selector(devicesChanged:) name:name object:nil];
    }
    [self refreshDevices];
}

- (void)devicesChanged:(NSNotification *)notification {
    [self refreshDevices];
}

- (NSDictionary *)snapshot:(DRDevice *)device diskSession:(DASessionRef)diskSession {
    NSDictionary *info = device.info;
    NSDictionary *status = device.status;
    NSDictionary *media = status[DRDeviceMediaInfoKey] ?: @{};
    NSDictionary *capabilities = info[DRDeviceWriteCapabilitiesKey] ?: @{};
    NSString *mediaClass = media[DRDeviceMediaClassKey] ?: @"";
    NSNumber *protection = nil;
    if ([mediaClass isEqual:DRDeviceMediaClassCD]) protection = capabilities[DRDeviceCanUnderrunProtectCDKey];
    if ([mediaClass isEqual:DRDeviceMediaClassDVD]) protection = capabilities[DRDeviceCanUnderrunProtectDVDKey];
    double base = [mediaClass isEqual:DRDeviceMediaClassCD] ? DRDeviceBurnSpeedCD1x :
                  [mediaClass isEqual:DRDeviceMediaClassBD] ? DRDeviceBurnSpeedBD1x : DRDeviceBurnSpeedDVD1x;
    NSMutableDictionary *result = [@{
        @"id": device.ioRegistryEntryPath ?: @"", @"name": device.displayName ?: @"光盘驱动器",
        @"media": device.mediaType ?: @"未插入光盘", @"present": @(device.mediaIsPresent),
        @"blank": @(device.mediaIsBlank), @"busy": @(device.mediaIsBusy || device.mediaIsTransitioning),
        @"canWrite": capabilities[DRDeviceCanWriteKey] ?: @NO,
        @"freeBlocks": media[DRDeviceMediaBlocksFreeKey] ?: @0,
        @"mediaBSDName": media[DRDeviceMediaBSDNameKey] ?: @"",
        @"mediaTrackCount": media[DRDeviceMediaTrackCountKey] ?: @0,
        @"mediaSessionCount": media[DRDeviceMediaSessionCountKey] ?: @0,
        @"speeds": status[DRDeviceBurnSpeedsKey] ?: @[], @"baseSpeed": @(base)
    } mutableCopy];
    NSString *bsdName = media[DRDeviceMediaBSDNameKey];
    if (diskSession && bsdName.length) {
        DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, diskSession, bsdName.UTF8String);
        if (disk) {
            NSDictionary *description = CFBridgingRelease(DADiskCopyDescription(disk));
            NSString *volumeName = description[(__bridge NSString *)kDADiskDescriptionVolumeNameKey];
            if (volumeName.length) result[@"volumeName"] = volumeName;
            CFRelease(disk);
        }
    }
    NSDictionary *hardwareKeys = @{
        @"vendor": DRDeviceVendorNameKey,
        @"product": DRDeviceProductNameKey,
        @"firmware": DRDeviceFirmwareRevisionKey,
        @"interconnect": DRDevicePhysicalInterconnectKey,
        @"location": DRDevicePhysicalInterconnectLocationKey
    };
    for (NSString *key in hardwareKeys) {
        id value = info[hardwareKeys[key]];
        if ([value isKindOfClass:NSString.class]) result[key] = value;
    }
    if ([result[@"location"] isEqual:DRDevicePhysicalInterconnectLocationInternal]) {
        result[@"location"] = @"Internal";
    } else if ([result[@"location"] isEqual:DRDevicePhysicalInterconnectLocationExternal]) {
        result[@"location"] = @"External";
    } else if ([result[@"location"] isEqual:DRDevicePhysicalInterconnectLocationUnknown]) {
        [result removeObjectForKey:@"location"];
    }
    NSMutableArray *writableMedia = [NSMutableArray array];
    for (NSArray *format in @[
        @[@"CD", DRDeviceCanWriteCDKey], @[@"DVD", DRDeviceCanWriteDVDKey],
        @[@"BD", DRDeviceCanWriteBDKey], @[@"HD DVD", DRDeviceCanWriteHDDVDKey]
    ]) {
        if ([capabilities[format[1]] boolValue]) [writableMedia addObject:format[0]];
    }
    if (writableMedia.count) result[@"writableMedia"] = writableMedia;
    // DiscRecording reports this MMC cache field in KiB (also shown as 'k' by drutil info).
    // Normalize to bytes at the bridge boundary; confirmed against this host's 4064k drive.
    uint64_t bufferKiB = [info[DRDeviceWriteBufferSizeKey] unsignedLongLongValue];
    if (bufferKiB > 0 && bufferKiB <= INT64_MAX / 1024) result[@"bufferCapacity"] = @(bufferKiB * 1024);
    if (protection) result[@"underrunProtection"] = protection;
    return result;
}

- (void)refreshDevices {
    NSMutableArray *devices = [NSMutableArray array];
    DASessionRef diskSession = DASessionCreate(kCFAllocatorDefault);
    for (DRDevice *device in DRDevice.devices) {
        if (device.isValid) {
            [devices addObject:[self snapshot:device diskSession:diskSession]];
        }
    }
    if (diskSession) CFRelease(diskSession);
    if (self.onDevices) self.onDevices(devices);
}

- (void)prepareImageAtURL:(NSURL *)url completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion {
    if (self.burn) { completion(nil, BRError(@"刻录期间无法更换镜像。")); return; }
    NSUInteger generation = ++self.preparationGeneration;
    self.layout = nil;
    self.imageURL = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            id layout = nil;
            uint64_t blocks = 0, bytes = 0;
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];
            NSSet *extensions = [NSSet setWithArray:@[@"iso", @"dmg", @"cdr", @"cue", @"toc"]];
            if (!url.isFileURL || ![extensions containsObject:url.pathExtension.lowercaseString]) {
                error = BRError(@"请选择 ISO、DMG、CDR、CUE 或 TOC 光盘镜像。BIN 文件请通过配套 CUE 导入。");
            } else if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] == 0) {
                error = BRError(@"镜像为空、不可读或不是普通文件。");
            }
            if (!error) {
                @try {
                    layout = [DRBurn layoutForImageFile:url.path];
                    NSArray *tracks = BRTracks(layout);
                    if (!layout || tracks.count == 0) error = BRError(@"系统无法解析此镜像。请检查镜像格式，以及 CUE/TOC 引用的数据文件。");
                    for (DRTrack *track in tracks) {
                        uint64_t length = track.estimateLength;
                        // Image layouts defer block-format properties until prepareTrack.
                        // Capacity is expressed in logical 2048-byte sectors, including audio layouts.
                        uint64_t blockSize = 2048;
                        if (!length || !blockSize || length > UINT64_MAX / blockSize ||
                            UINT64_MAX - blocks < length || UINT64_MAX - bytes < length * blockSize) {
                            error = BRError(@"镜像轨道大小无效，无法安全刻录。"); break;
                        }
                        blocks += length;
                        bytes += length * blockSize;
                        NSMutableDictionary *properties = [track.properties mutableCopy];
                        // Verify the bytes actually sent to the drive, including every track.
                        properties[DRVerificationTypeKey] = DRVerificationTypeChecksum;
                        [track setProperties:properties];
                    }
                } @catch (NSException *exception) {
                    error = BRError([@"镜像解析失败：" stringByAppendingString:exception.reason ?: @"未知格式"]);
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.preparationGeneration) {
                    completion(nil, BRError(@"镜像选择已改变。")); return;
                }
                if (error) { completion(nil, error); return; }
                self.layout = layout;
                self.imageURL = url;
                self.imageAttributes = attributes;
                self.requiredBlocks = blocks;
                completion(@{@"name": url.lastPathComponent, @"fileBytes": attributes[NSFileSize],
                             @"burnBytes": @(bytes), @"blocks": @(blocks),
                             @"tracks": @(BRTracks(layout).count)}, nil);
            });
        }
    });
}

- (void)logDiagnostic:(NSString *)message {
    if (self.onDiagnostic) self.onDiagnostic(message);
}

- (void)logTrackSpeeds:(NSString *)context {
    if (!self.onDiagnostic) return;
    NSArray<DRTrack *> *tracks = BRTracks(self.layout);
    for (NSUInteger index = 0; index < tracks.count; index++) {
        id limit = tracks[index].properties[DRMaxBurnSpeedKey];
        [self logDiagnostic:[NSString stringWithFormat:
            @"[轨道速度上限 · %@] 轨道 %lu；DRMaxBurnSpeedKey=%@",
            context, (unsigned long)index + 1,
            limit ? [NSString stringWithFormat:@"%@ KB/s", limit] : @"未设置（SDK 默认不限速）"]];
    }
}

- (BOOL)startOnDevice:(NSString *)identifier speed:(double)speed finalize:(BOOL)finalize
               verify:(BOOL)verify eject:(BOOL)eject error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Use BRDiscEngine on the main thread");
    [self logDiagnostic:[NSString stringWithFormat:
        @"[原生速度请求] 设备 ID=%@；输入 speed=%.3f；DRBurnRequestedSpeedKey=%@%@",
        identifier, speed, @(speed > 0 ? speed : DRDeviceBurnSpeedMax),
        speed > 0 ? @" KB/s" : @"（DRDeviceBurnSpeedMax，自动最高速度标记，并非实际 KB/s）"]];
    [self logTrackSpeeds:@"写入前"];
    NSString *failure = nil;
    DRDevice *device = [DRDevice deviceForIORegistryEntryPath:identifier];
    NSDictionary *attributes = self.imageURL ? [NSFileManager.defaultManager attributesOfItemAtPath:self.imageURL.path error:nil] : nil;
    if (self.burn) failure = @"已有刻录任务正在运行。";
    else if (!self.layout || !attributes) failure = @"请重新选择可读取的镜像。";
    else if (![attributes[NSFileModificationDate] isEqual:self.imageAttributes[NSFileModificationDate]] ||
             ![attributes[NSFileSize] isEqual:self.imageAttributes[NSFileSize]] ||
             ![attributes[NSFileSystemFileNumber] isEqual:self.imageAttributes[NSFileSystemFileNumber]]) failure = @"镜像文件已改变，请重新选择。";
    else if (!device || !device.isValid) failure = @"刻录设备已断开连接。";
    else if (device.mediaIsBusy || device.mediaIsTransitioning) failure = @"刻录设备正忙，请稍后重试。";
    else if (!device.mediaIsPresent) failure = @"请插入一张空白可写光盘。";
    // Existing contents are never erased or appended to implicitly.
    else if (!device.mediaIsBlank) failure = @"请使用空白光盘；Disc Studio 不会自动擦除已有数据。";
    else {
        NSDictionary *snapshot = [self snapshot:device diskSession:NULL];
        [self logDiagnostic:[NSString stringWithFormat:
            @"[设备与介质] 型号=%@；固件=%@；连接=%@；位置=%@；介质=%@；1×=%@ KB/s",
            snapshot[@"name"], snapshot[@"firmware"] ?: @"未提供", snapshot[@"interconnect"] ?: @"未提供",
            snapshot[@"location"] ?: @"未提供", snapshot[@"media"], snapshot[@"baseSpeed"]]];
        [self logDiagnostic:[NSString stringWithFormat:@"[支持写入速度] DRDeviceBurnSpeedsKey（KB/s）=%@",
            [snapshot[@"speeds"] count] ? [snapshot[@"speeds"] componentsJoinedByString:@", "] : @"未提供"]];
        if ([snapshot[@"freeBlocks"] unsignedLongLongValue] < self.requiredBlocks) failure = @"光盘可用容量不足，或设备尚未报告容量。";
        if (speed > 0 && ![snapshot[@"speeds"] containsObject:@(speed)]) failure = @"当前光盘不再支持所选速度，请刷新设备后重试。";
    }
    if (failure) { if (error) *error = BRError(failure); return NO; }
    @try {
        // Each burn session owns its layout, notification observer and sleep assertion.
        // Session engines need burn notifications without observing the device inventory.
        if (!self.center) self.center = [DRNotificationCenter currentRunLoopCenter];
        DRBurn *burn = [[DRBurn alloc] initWithDevice:device];
        [burn setProperties:@{DRBurnRequestedSpeedKey: @(speed > 0 ? speed : DRDeviceBurnSpeedMax),
                              DRBurnAppendableKey: @(!finalize), DRBurnVerifyDiscKey: @(verify),
                              DRBurnUnderrunProtectionKey: @YES,
                              DRBurnCompletionActionKey: eject ? DRBurnCompletionActionEject : DRBurnCompletionActionMount,
                              DRBurnFailureActionKey: DRBurnFailureActionNone}];
        self.burn = burn;
        self.lastDiagnosticState = nil;
        [self logDiagnostic:[NSString stringWithFormat:@"[引擎速度属性] DRBurnRequestedSpeedKey=%@%@",
            burn.properties[DRBurnRequestedSpeedKey] ?: @"未提供",
            speed > 0 ? @" KB/s" : @"（自动最高速度标记）"]];
        self.cancellationRequested = NO;
        self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityIdleSystemSleepDisabled
                                                                   reason:@"正在刻录并校验光盘"];
        [self.center addObserver:self selector:@selector(burnChanged:) name:DRBurnStatusChangedNotification object:burn];
        [burn writeLayout:self.layout];
        [self publishStatus:burn.status];
        return YES;
    } @catch (NSException *exception) {
        [self finishBurn];
        if (error) *error = BRError(exception.reason ?: @"无法启动刻录。");
        return NO;
    }
}

- (void)burnChanged:(NSNotification *)notification {
    if (notification.object != self.burn) return;
    [self publishStatus:notification.userInfo ?: self.burn.status];
}

- (void)publishStatus:(NSDictionary *)status {
    NSString *state = status[DRStatusStateKey];
    NSString *phase = @"preparing";
    if ([state isEqual:DRStatusStateTrackWrite]) phase = @"writing";
    else if ([state isEqual:DRStatusStateTrackClose] || [state isEqual:DRStatusStateSessionClose] ||
             [state isEqual:DRStatusStateFinishing]) phase = @"finishing";
    else if ([state isEqual:DRStatusStateVerifying]) phase = @"verifying";
    else if ([state isEqual:DRStatusStateDone]) phase = @"completed";
    else if ([state isEqual:DRStatusStateFailed]) phase = @"failed";
    NSDictionary *failure = status[DRErrorStatusKey];
    uint32_t errorCode = [failure[DRErrorStatusErrorKey] unsignedIntValue];
    if ([phase isEqual:@"failed"] && errorCode == kDRUserCanceledErr) phase = @"cancelled";
    BOOL terminal = [@[@"completed", @"failed", @"cancelled"] containsObject:phase];
    NSMutableDictionary *result = [@{@"phase": phase, @"rawState": state ?: @"",
        @"cancelling": @(self.cancellationRequested && !terminal)} mutableCopy];
    if (status[DRStatusPercentCompleteKey]) result[@"progress"] = status[DRStatusPercentCompleteKey];
    NSDictionary *progress = status[DRStatusProgressInfoKey];
    if (status[DRStatusCurrentSpeedKey]) result[@"currentSpeedRaw"] = [status[DRStatusCurrentSpeedKey] description];
    NSString *diagnosticState = [NSString stringWithFormat:@"%@ / track=%@", state ?: @"未提供",
                                status[DRStatusCurrentTrackKey] ?: @"未提供"];
    if (![diagnosticState isEqual:self.lastDiagnosticState]) {
        self.lastDiagnosticState = diagnosticState;
        [self logDiagnostic:[NSString stringWithFormat:@"[原生状态] %@；DRStatusCurrentSpeedKey(raw)=%@",
            diagnosticState, result[@"currentSpeedRaw"] ?: @"未提供"]];
        // Image producers may fill track properties only when preparing the actual burn.
        if ([phase isEqual:@"writing"]) [self logTrackSpeeds:@"进入写入"];
    }
    if ([phase isEqual:@"writing"]) {
        NSNumber *speed = progress[DRStatusProgressCurrentKPS];
        if (speed) result[@"speedKB"] = speed;
        if (progress[DRStatusProgressCurrentXFactor]) result[@"speedX"] = progress[DRStatusProgressCurrentXFactor];
    }
    if (status[DRStatusCurrentTrackKey]) result[@"track"] = status[DRStatusCurrentTrackKey];
    if (failure) {
        result[@"error"] = failure[DRErrorStatusErrorStringKey] ?: @"刻录失败，请检查连接和光盘。";
        result[@"errorCode"] = @(errorCode);
        if (failure[DRErrorStatusErrorInfoStringKey]) result[@"errorDetail"] = failure[DRErrorStatusErrorInfoStringKey];
    }
    if (terminal) [self finishBurn];
    if (self.onStatus) self.onStatus(result);
    if (terminal) [self refreshDevices];
}

- (void)finishBurn {
    if (self.burn) [self.center removeObserver:self name:DRBurnStatusChangedNotification object:self.burn];
    self.burn = nil;
    if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
    self.activity = nil;
}

- (void)cancel {
    if (!self.burn || self.cancellationRequested) return;
    self.cancellationRequested = YES;
    [self.burn abort];
}

- (BOOL)ejectDevice:(NSString *)identifier error:(NSError **)error {
    DRDevice *device = [DRDevice deviceForIORegistryEntryPath:identifier];
    if (self.burn || !device || !device.isValid || ![device ejectMedia]) {
        if (error) *error = BRError(@"无法弹出光盘。设备可能正忙或已断开。");
        return NO;
    }
    return YES;
}

- (void)dealloc {
    [_center removeObserver:self name:nil object:nil];
    if (_activity) [NSProcessInfo.processInfo endActivity:_activity];
}
@end
