//
//  SocketOperation.m
//  MobileCMS
//
//  Created by 王勇 on 15/7/24.
//

#import "SocketOperation.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>


#ifdef DEBUG // 处于开发阶段
//#define SOCKETLOG(...) NSLog(__VA_ARGS__)
#define SOCKETLOG(...)
#else // 处于发布阶段
#define SOCKETLOG(...)
#endif



typedef NS_ENUM(NSInteger, socketOperationState) {
    socketOperationPausedState    = -1,
    socketOperationReadyState     = 1,
    socketOperationExecutingState = 2,
    socketOperationFinishedState  = 3,
};

//与NSOperation 对应才能kvo发出通知
static inline NSString * socketKeyPathFromOperationState(socketOperationState state) {
    switch (state) {
        case socketOperationReadyState:
            return @"isReady";
        case socketOperationExecutingState:
            return @"isExecuting";
        case socketOperationFinishedState:
            return @"isFinished";
        case socketOperationPausedState:
            return @"isPaused";
        default: {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
            return @"state";
#pragma clang diagnostic pop
        }
    }
}

static inline BOOL socketStateTransitionIsValid(socketOperationState fromState, socketOperationState toState, BOOL isCancelled) {
    switch (fromState) {
        case socketOperationReadyState:
            switch (toState) {
                case socketOperationPausedState:
                case socketOperationExecutingState:
                    return YES;
                case socketOperationFinishedState:
                    return isCancelled;
                default:
                    return NO;
            }
        case socketOperationExecutingState:
            switch (toState) {
                case socketOperationPausedState:
                case socketOperationFinishedState:
                    return YES;
                default:
                    return NO;
            }
        case socketOperationFinishedState:
            return NO;
        case socketOperationPausedState:
            return toState == socketOperationReadyState;
        default: {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
            switch (toState) {
                case socketOperationPausedState:
                case socketOperationReadyState:
                case socketOperationExecutingState:
                case socketOperationFinishedState:
                    return YES;
                default:
                    return NO;
            }
        }
#pragma clang diagnostic pop
    }
}

static dispatch_group_t socket_request_operation_completion_group() {
    static dispatch_group_t socket_request_operation_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        socket_request_operation_completion_group = dispatch_group_create();
    });
    
    return socket_request_operation_completion_group;
}

static dispatch_queue_t socket_request_operation_completion_queue() {
    static dispatch_queue_t socket_url_request_operation_completion_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        socket_url_request_operation_completion_queue = dispatch_queue_create("com.zjhc.networking.operation.queue", DISPATCH_QUEUE_CONCURRENT );
    });
    
    return socket_url_request_operation_completion_queue;
}

static NSString * const kSocketNetworkingLockName = @"com.zjhc.networking.operation.lock";


@interface SocketOperation()<NSStreamDelegate>

@property (readwrite, nonatomic, assign) socketOperationState state;

@property (readwrite, nonatomic, strong) NSRecursiveLock      *lock;

@property (readwrite, nonatomic, strong) NSError              *error;

@property (readwrite, nonatomic, strong) NSInputStream        *inputStream;//接收socket数据

@property (readwrite, nonatomic, strong) NSOutputStream       *outputStream;//发送socket数据


@property (nonatomic,strong            ) NSData               *responseData;


@end


@implementation SocketOperation{
    
    NSString *_ip;
    int _port;
    int _timeOut;
    
    dispatch_source_t writeTimer;
    
    dispatch_source_t readTimer;
}


+ (void)networkRequestThreadEntryPoint:(id)__unused object {
    @autoreleasepool {
        [[NSThread currentThread] setName:@"socketNetworking"];
        
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        [runLoop run];
    }
}

+ (NSThread *)networkRequestThread {
    static NSThread *_networkRequestThread = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _networkRequestThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRequestThreadEntryPoint:) object:nil];
        [_networkRequestThread start];
    });
    
    return _networkRequestThread;
}


-(instancetype)init{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _ip=@"127.0.0.1";
    
    _port=9007;
    
    _timeOut=30;
    
    
    _state = socketOperationReadyState;
    
    self.lock = [[NSRecursiveLock alloc] init];
    self.lock.name = kSocketNetworkingLockName;
    
    self.runLoopModes = [NSSet setWithObject:NSRunLoopCommonModes];
    
    return self;
}

//******************************重写NSOperation的方法

- (void)setState:(socketOperationState)state {
    if (!socketStateTransitionIsValid(self.state, state, [self isCancelled])) {
        return;
    }
    
    [self.lock lock];
    NSString *oldStateKey = socketKeyPathFromOperationState(self.state);
    NSString *newStateKey = socketKeyPathFromOperationState(state);
    
    [self willChangeValueForKey:newStateKey];
    [self willChangeValueForKey:oldStateKey];
    _state = state;
    [self didChangeValueForKey:oldStateKey];
    [self didChangeValueForKey:newStateKey];
    [self.lock unlock];
}

- (void)setCompletionBlock:(void (^)(void))block {
    [self.lock lock];
    if (!block) {
        [super setCompletionBlock:nil];
    } else {
        __weak __typeof(self)weakSelf = self;
        [super setCompletionBlock:^ {
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            
            dispatch_group_t group = socket_request_operation_completion_group();
            
            //TODO 这个队列是否使用主线程
            dispatch_queue_t queue =  dispatch_get_main_queue();
            
            dispatch_group_async(group, queue, ^{
                block();
            });
            
            dispatch_group_notify(group, socket_request_operation_completion_queue(), ^{
                [strongSelf setCompletionBlock:nil];
            });
        }];
    }
    
    [self.lock unlock];
}

- (BOOL)isReady {
    return self.state == socketOperationReadyState && [super isReady];
}

- (BOOL)isExecuting {
    return self.state == socketOperationExecutingState;
}

- (BOOL)isFinished {
    return self.state == socketOperationFinishedState;
}

- (BOOL)isConcurrent {
    return YES;
}

-(void)start{
    [self.lock lock];
    if ([self isReady]) {
        self.state = socketOperationExecutingState;
        [self performSelector:@selector(operationDidStart) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
    }
    [self.lock unlock];
    
}

//*******************************


- (void)operationDidStart {
    [self.lock lock];
    NSDictionary *dictionary =  [[NSUserDefaults standardUserDefaults]objectForKey:@"baseSet"];
    if (![self isCancelled]) {
        
        CFReadStreamRef readStream=NULL;
        CFWriteStreamRef writeStream=NULL;
        SOCKETLOG(@"开始连接**************%@*******%d",ip,port);
        //无法确定连接是否成功
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,(__bridge CFStringRef) _ip, _port, &readStream, &writeStream);
        
        
        self.inputStream = (__bridge NSInputStream *)(readStream);
        self.outputStream = (__bridge NSOutputStream *)(writeStream);
        
        self.inputStream.delegate = self;
        self.outputStream.delegate = self;
        
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        
        
         //让读取跟写出都在同一个线程里
        for (NSString *runLoopMode in self.runLoopModes) {
            [self.inputStream scheduleInRunLoop:runLoop forMode:runLoopMode];
            [self.outputStream scheduleInRunLoop:runLoop forMode:runLoopMode];
        }
        [self.inputStream open];
        [self.outputStream open];
        
        //开启写超时
        [self startWriteTimeout:_timeOut];
    }
    [self.lock unlock];
    
}

-(void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode{
    SOCKETLOG(@"%@",aStream);
    //    NSStreamEventOpenCompleted = 1UL << 0,
    //    NSStreamEventHasBytesAvailable = 1UL << 1,
    //    NSStreamEventHasSpaceAvailable = 1UL << 2,
    //    NSStreamEventErrorOccurred = 1UL << 3,
    //    NSStreamEventEndEncountered = 1UL << 4
    switch (eventCode) {
        case NSStreamEventOpenCompleted://数据流打开完成
            SOCKETLOG(@"数据流打开完成");
            break;
        case NSStreamEventHasBytesAvailable://有可读字节
        {
            [self endWritetTimeout];
            [self startReadTimeout:_timeOut];
            [self readBytes];
        }
            break;
        case NSStreamEventHasSpaceAvailable:// 可发送字节
            SOCKETLOG(@"可发送字节");
            [self sendData];
            break;
        case NSStreamEventErrorOccurred://连接错误
        {
            SOCKETLOG(@"链接错误");
            self.error =[[NSError alloc]initWithDomain:@"连接错误" code:NSSocketOperationConnetctError userInfo:nil];
            [self finish];
        }
            break;
        case NSStreamEventEndEncountered://到达流未尾，要关闭输入输出流
            SOCKETLOG(@"到达流未尾，要关闭输入输出流");
            //            [self closeSocketBySelf];
            break;
        default:
            break;
    }
}

-(void)dealloc{
    SOCKETLOG(@"销毁了****************");
    if (self.outputStream) {
        [self.outputStream close];
        self.outputStream=nil;
    }
    
    if (self.inputStream) {
        [self.inputStream close];
        self.inputStream=nil;
    }
    
}

- (void)finish {
    [self.lock lock];
    [self closeSocketBySelf];
    self.state = socketOperationFinishedState;
    [self.lock unlock];
    
}

- (void)cancel {
    [self.lock lock];
    if (![self isFinished] && ![self isCancelled]) {
        [super cancel];
        [self performSelector:@selector(cancelConnection) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
    }
    [self.lock unlock];
}

/**
 @author wangyong, 15-07-25 08:07:50
 
 设置operation执行结束之后的回调
 block  self 引用循环问题的解决
 completionBlock is manually nilled out in SocketOperation to break the retain cycle.
 
 @param success 成功的操作
 @param failure 失败的操作
 */
- (void)setCompletionBlockWithSuccess:(SuccessOption) success failure:(FailureOption)failure{
    // completionBlock is manually nilled out in SocketOperation to break the retain cycle.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
#pragma clang diagnostic ignored "-Wgnu"
    self.completionBlock = ^{
        dispatch_async(socket_request_operation_completion_queue(), ^{
            if (self.error) {
                if (failure) {
                    dispatch_group_async(socket_request_operation_completion_group(), dispatch_get_main_queue(), ^{
                        failure(self.error);
                    });
                }
            } else {
                if (self.error) {
                    if (failure) {
                        dispatch_group_async(socket_request_operation_completion_group(), dispatch_get_main_queue(), ^{
                            failure(self.error);
                        });
                    }
                } else {
                    if (success) {
                        dispatch_group_async(socket_request_operation_completion_group(), dispatch_get_main_queue(), ^{
                            success(self.responseData);
                        });
                    }
                }
            }
        });
    };
#pragma clang diagnostic pop
}

-(void)cancelConnection{
    if (![self isFinished]) {
        if (self.outputStream||self.inputStream) {
            [self closeSocketBySelf];
            [self finish];
        } else {
            [self finish];
        }
    }
}


-(void)closeSocketBySelf{
    SOCKETLOG(@"**********关闭socket连接");
    
    if (self.outputStream) {
        [self.outputStream close];
        self.outputStream=nil;
    }
    
    if (self.inputStream) {
        [self.inputStream close];
        self.inputStream=nil;
    }
    
}

/**
 @author wangyong, 15-07-25 08:07:13
 
 发送数据
 */
-(void)sendData{
    
    long long remainingToWrite = self.writeData.length;
    void * marker = (void *)[self.writeData bytes];
    int actuallyWritten;
    int totalActualWritten=0;
    SOCKETLOG(@"**********发送总长度＝%lu,sendData%@",(unsigned long)[self.writeData length],[NSThread currentThread]);
    while ([self.outputStream hasSpaceAvailable]) {
        
        if (remainingToWrite > 0) {
            actuallyWritten = 0;
            if(remainingToWrite < (1024*32)){
                actuallyWritten = [self.outputStream write:marker maxLength:remainingToWrite];//不足32KB数据时发送剩余部分
            }
            else{
                actuallyWritten = [self.outputStream write:marker maxLength:(1024*32)];//每次32KB数据
            }
            SOCKETLOG(@"发送的长度＝%d",actuallyWritten);
            if ((actuallyWritten == -1) || (actuallyWritten == 0))
            {
                [self closeSocketBySelf];
            }
            else
            {
                remainingToWrite -= actuallyWritten;
                marker += actuallyWritten;
                totalActualWritten+=actuallyWritten;
            }
        }
        else
        {
            break;
        }
    }
    self.writeData=nil;
}

/**
 @author wangyong, 15-07-25 08:07:22
 
 接收数据(需要开发者自己定义规则)
 */
-(void)readBytes{
   
    //读取data数据，每个公司可能有自己读取的规则
    
    
    //读取之后的值赋值给responseData
    
    
    //结束调用completionBlock
    [self finish];
}




//**************************以下是定时任务相关处理
/**
 开始定时任务
 
 @param timeout <#timeout description#>
 */
- (void)startWriteTimeout:(NSTimeInterval)timeout
{
    if (writeTimer) {
        return;
    }
    if (timeout >= 0.0)
    {
        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        writeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        
        __weak SocketOperation *weakSelf = self;
        
        dispatch_source_set_event_handler(writeTimer, ^{ @autoreleasepool {
            __strong SocketOperation *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            
            [strongSelf doWritetTimeout];
            
        }});
        
        dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
        dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
        SOCKETLOG(@"启动写超时设置********write");
        dispatch_resume(writeTimer);
    }
}
/**
 超时处理
 */
- (void)doWritetTimeout
{
    [self endWritetTimeout];
    SOCKETLOG(@"写超时*****");
    NSError *error=[[NSError alloc]initWithDomain:@"发送数据超时" code:NSSocketOperationWriteTimeOut userInfo:nil];
    self.error = error;
    [self cancel];
}
/**
 取消写超时的检查
 */
- (void)endWritetTimeout
{
    SOCKETLOG(@"取消写超时设置");
    if (writeTimer)
    {
        dispatch_source_cancel(writeTimer);
        writeTimer = NULL;
    }
}

/**
 启动读定时任务检查
 
 @param timeout <#timeout description#>
 */
- (void)startReadTimeout:(NSTimeInterval)timeout
{
    //如果读取的超时任务已开始
    if (readTimer) {
        return;
    }
    
    if (timeout >= 0.0)
    {
        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        readTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        
        __weak SocketOperation *weakSelf = self;
        
        dispatch_source_set_event_handler(readTimer, ^{ @autoreleasepool {
            __strong SocketOperation *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            
            [strongSelf doReadTimeout];
            
        }});
        
        dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
        dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
        SOCKETLOG(@"启动读取超时设置********read");
        dispatch_resume(readTimer);
    }
}
/**
 读取超时
 */
- (void)doReadTimeout
{
    [self endReadTimeout];
    SOCKETLOG(@"读超时*****");
    NSError *error=[[NSError alloc]initWithDomain:@"读取数据超时" code:NSSocketOperationReadTimeOut userInfo:nil];
    self.error = error;
    [self cancel];
}

/**
 结束读取超时
 */
- (void)endReadTimeout
{
    SOCKETLOG(@"取消读取超时设置");
    if (readTimer)
    {
        dispatch_source_cancel(readTimer);
        readTimer = NULL;
    }
}



@end
