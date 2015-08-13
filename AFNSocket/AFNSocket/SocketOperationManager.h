//
//  SocketOperationManager.h
//
//  Created by 王勇 on 15/7/24.
//

#import <Foundation/Foundation.h>
#import "SocketOperation.h"

@interface SocketOperationManager : NSObject

@property (nonatomic, strong) NSOperationQueue *operationQueue;

+ (instancetype)manager;

-(void)writeData:(NSData *)data success:(SuccessOption) success failure:(FailureOption)failure;


@end
