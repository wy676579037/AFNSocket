//
//  SocketOperation.h
//  MobileCMS
//
//  Created by 王勇 on 15/7/24.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SocketOperationError) {
    NSSocketOperationConnetctError = -1L,
    NSSocketOperationWriteTimeOut,
    NSSocketOperationReadTimeOut
};


//根据自己不同业务的需求进行修改
typedef  void (^SuccessOption)(NSData *data);

typedef  void (^FailureOption)(NSError* error);

@interface SocketOperation : NSOperation


@property (nonatomic, strong) NSSet  *runLoopModes;

@property (nonatomic, strong) NSData *writeData;

- (void)setCompletionBlockWithSuccess:(SuccessOption) success failure:(FailureOption)failure;



@end
