#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Raw-byte storage prepared in the background, then owned by the main actor.
NS_SWIFT_MAIN_ACTOR
@interface DPScintillaBinaryDocument : NSObject
@property(nonatomic, readonly) NSUInteger byteLength;
@property(nonatomic, readonly) NSUInteger totalByteLength;
- (void)cancelLoading;
+ (void)prepareData:(NSData *)data
  completionHandler:(void (^)(DPScintillaBinaryDocument * _Nullable document,
                               NSError * _Nullable error))completionHandler
    NS_SWIFT_NAME(prepare(data:completionHandler:));
+ (void)beginData:(NSData *)data
 completionHandler:(void (^)(DPScintillaBinaryDocument * _Nullable document,
                              NSError * _Nullable error))completionHandler
    NS_SWIFT_NAME(begin(data:completionHandler:));
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
