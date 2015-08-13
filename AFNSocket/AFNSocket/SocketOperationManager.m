//
//  SocketOperationManager.m
//
//  Created by 王勇 on 15/7/24.
//

#import "SocketOperationManager.h"
#import "SocketOperation.h"

/**
 @author wangyong, 15-08-13 14:08:31
 
 socket短连接的一个写法
 */
@implementation SocketOperationManager


+(instancetype)manager{
    SocketOperationManager *manager = [SocketOperationManager new];
    if (!manager) {
        return nil;
    }
    //初始化操作队列
    manager.operationQueue = [[NSOperationQueue alloc] init];
    return manager;
}


//IP，端口现在,SocketOperation这个类里
-(void)writeData:(NSData *)data success:(SuccessOption) success failure:(FailureOption)failure{
    //创建Operation
    SocketOperation *operation = [[SocketOperation alloc]init];
    operation.writeData =data;
    [operation setCompletionBlockWithSuccess:success failure:failure];
    //加入队列开始运行
    [self.operationQueue addOperation:operation];
}


@end
