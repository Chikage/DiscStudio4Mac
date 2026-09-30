#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Methods and callbacks are confined to the main thread. Image parsing runs off-main.
@interface BRDiscEngine : NSObject
@property (nonatomic, copy, nullable) void (^onDevices)(NSArray<NSDictionary<NSString *, id> *> *);
@property (nonatomic, copy, nullable) void (^onStatus)(NSDictionary<NSString *, id> *);
@property (nonatomic, copy, nullable) void (^onDiagnostic)(NSString *);
- (void)observeDevices;
- (void)refreshDevices;
- (void)prepareImageAtURL:(NSURL *)url completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion;
- (BOOL)startOnDevice:(NSString *)identifier speed:(double)speed finalize:(BOOL)finalize verify:(BOOL)verify eject:(BOOL)eject error:(NSError **)error;
- (void)cancel;
- (BOOL)ejectDevice:(NSString *)identifier error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
