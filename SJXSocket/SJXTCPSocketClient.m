//
//  SJXTCPSocketClient.m
//  TCPDemo
//
//  Created by shapp on 2018/1/26.
//  Copyright © 2018年 shapp. All rights reserved.
//

#define ADDR_STR_LEN            512         //!< url length
#define MODEL_LENGTH            2           // 验证用户名密码读写长度

#define TAG_LOCAL_CONNECT       10010       // local socket 开始连接
#define TAG_GET_REQUEST         10020       // 获取请求数据
#define TAG_LOCAL_TO_REMOTE     10030       // 从本地读取数据，转发到远端
#define TAG_TCP_AUTH_FIRST      20010       // 鉴权第一步
#define TAG_TCP_AUTH_SECOND     20020       // 鉴权第二步
#define TAG_TCP_SEND            20030       // 进行tcp请求代理
#define TAG_WRITE_TO_LOCAL      30010       // 写入本地数据
#define TAG_WRITE_TO_REMOTE     30020       // 写入远端数据
#define TAG_READ_FROM_LOCAL     40010       // 从本地读取数据
#define TAG_READ_FROM_REMOTE    40020       // 从远端读取数据

#define ERROR_TCP_BIND          50001       // tcp 端口绑定失败

#import "SJXTCPSocketClient.h"
#import "GCDAsyncSocket.h"
#include <arpa/inet.h>
#include "encrypt.h"
#include "socks5.h"

NSString *const SJXTCPSocksClientErrorDomain = @"SJXTCPSocksClientErrorDomain";

#pragma mark - <SJXPipeline>
@interface SJXPipeline : NSObject
{
@public
    struct encryption_ctx sendEncryptionContext;
    struct encryption_ctx recvEncryptionContext;
}

@property (nonatomic, strong) GCDAsyncSocket *localSocket;  // 本地 socket 连接
@property (nonatomic, strong) GCDAsyncSocket *remoteSocket; // 远端 socket 连接
@property (nonatomic, strong) NSData *addrData;
@property (nonatomic, strong) NSData *requestData;
@property (nonatomic, strong) NSData *destinationData;    // 用于存储将目标地址解析后的数据

- (void)disconnect;

@end

@implementation SJXPipeline

- (void)disconnect {
    [self.localSocket disconnectAfterReadingAndWriting];
    [self.remoteSocket disconnectAfterReadingAndWriting];
}

@end

#pragma mark - <SJXTCPSocketClient>
@interface SJXTCPSocketClient () <GCDAsyncSocketDelegate>
{
    GCDAsyncSocket *_serverSocket;   // 用于监听本地端口
    NSMutableArray *_pipelines;      // 所有连接Socks Server 的Object
    NSString *_host;
    NSInteger _port;
}

@end

@implementation SJXTCPSocketClient

@synthesize host = _host;
@synthesize port = _port;

#pragma mark - 根据Local/Remote Socket,查找Super Object
/**
 *  根据当前local socket对象查找父对象
 *
 *  @param localSocket localSocket
 *
 *  @return SJXPipeline Object
 */
- (SJXPipeline *)pipelineOfLocalSocket:(GCDAsyncSocket *)localSocket {
    __block SJXPipeline *ret;
    [_pipelines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SJXPipeline *pipeline = obj;
        if (pipeline.localSocket == localSocket) {
            ret = pipeline;
        }
    }];
    return ret;
}

/**
 *  根据当前remote socket对象查找父对象
 *
 *  @param remoteSocket remoteSocket
 *
 *  @return SJXPipeline Object
 */
- (SJXPipeline *)pipelineOfRemoteSocket:(GCDAsyncSocket *)remoteSocket {
    __block SJXPipeline *ret;
    [_pipelines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SJXPipeline *pipeline = obj;
        if (pipeline.remoteSocket == remoteSocket) {
            ret = pipeline;
        }
    }];
    return ret;
}

#pragma mark - 外部调用接口
+ (instancetype)shareTcpScoketClient {
    static SJXTCPSocketClient * _client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _client = [[SJXTCPSocketClient alloc] init];
    });
    return _client;
}

- (void)setTcpHost:(NSString *)host port:(NSInteger)port {
    _host = [host copy];
    _port = port;
}

- (BOOL)startWithLocalPort:(NSInteger)localPort {
    [self stop];
    
    dispatch_queue_t queue = dispatch_queue_create("tcpLocalScoketQueueName", NULL);
    _serverSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:queue];
    NSError *error;
    [_serverSocket acceptOnPort:localPort error:&error];
    if (error) {
        [self.tcpClientDelegate tcpSocket:_serverSocket didFailWithError:error errorTag:ERROR_TCP_BIND];
        return NO;
    }
    _pipelines = [[NSMutableArray alloc] init];
    return YES;
}

- (void)stop {
    [_serverSocket disconnect];
    
    NSArray *ps = [NSArray arrayWithArray:_pipelines];
    [ps enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SJXPipeline *pipeline = obj;
        [pipeline.localSocket disconnect];
        [pipeline.remoteSocket disconnect];
    }];
    _serverSocket = nil;
}

- (BOOL)isConnected {
    return _serverSocket.isConnected;
}

#pragma mark - GCDAsyncSocketDelegate
- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    // 设置本地 socket 连接
    SJXPipeline *pipeline = [[SJXPipeline alloc] init];
    pipeline.localSocket = newSocket;
    [_pipelines addObject:pipeline];
    [pipeline.localSocket readDataWithTimeout:-1 tag:TAG_LOCAL_CONNECT];
}

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    // 获取远端 socket 对象
    SJXPipeline *pipeline = [self pipelineOfRemoteSocket:sock];
    
    if(self.consultMethod == SJXTCPSocksClientConsultMethodNO) {
        // 无需协商方式
        [pipeline.remoteSocket writeData:pipeline.addrData withTimeout:-1 tag:TAG_LOCAL_TO_REMOTE];
        // 转发
        [self socksFakeReply:pipeline];
    } else if(self.consultMethod == SJXTCPSocksClientConsultMethodUSRPSD) {
        // 进行第一步鉴权操作
        [self authFirstWithSocket:pipeline.remoteSocket];
    } else {
        // 其他协商方式
        
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    //    [self.tcpClientDelegate icgTcpSocket:sock didFailWithError:err errorTag:ERROR_DISCONNECT];
    SJXPipeline *pipeline;
    pipeline = [self pipelineOfRemoteSocket:sock];
    if (pipeline) { // disconnect remote
        if (pipeline.localSocket.isDisconnected) {
            [_pipelines removeObject:pipeline];
        } else {
            [pipeline.localSocket disconnectAfterReadingAndWriting];
        }
        return;
    }
    
    pipeline = [self pipelineOfLocalSocket:sock];
    if (pipeline) { // disconnect local
        if (pipeline.remoteSocket.isDisconnected) {
            [_pipelines removeObject:pipeline];
        } else {
            [pipeline.remoteSocket disconnectAfterReadingAndWriting];
        }
        return;
    }
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    // 获取当前 socket 连接对象
    SJXPipeline *pipeline = [self pipelineOfLocalSocket:sock] ? : [self pipelineOfRemoteSocket:sock];
    if (!pipeline) return;
    
    if (tag == TAG_LOCAL_CONNECT) { // socket 与本地连接
        [pipeline.localSocket writeData:[NSData dataWithBytes:"\x05\x00" length:2] withTimeout:-1 tag:TAG_LOCAL_CONNECT];
    } else if(tag == TAG_GET_REQUEST) { // 获取请求数据
        if(self.consultMethod == SJXTCPSocksClientConsultMethodNO) {
            // 无需协商方式
            [self setConsultMethodNoWithPipeline:pipeline];
        } else if(self.consultMethod == SJXTCPSocksClientConsultMethodUSRPSD) {
            // 使用 用户名和密码 的协商方式
            [self setConsultMethodUSRPSDWith:pipeline data:data];
        } else {
            // 其他协商方式
            
        }
    } else if (tag == TAG_LOCAL_TO_REMOTE) {
        // 从本地读取数据，转发到远端
        pipeline.destinationData = data;
        [pipeline.remoteSocket writeData:data withTimeout:-1 tag:TAG_WRITE_TO_REMOTE];
    } else if (tag == TAG_TCP_AUTH_FIRST) {
        // 第一步鉴权判断
        [self authFirstPassWithPipeline:pipeline data:data];
    }
    else if (tag == TAG_TCP_AUTH_SECOND) {
        // 第二步鉴权判断
        [self authSecondPassWithPipeline:pipeline data:data];
    } else if (tag == TAG_TCP_SEND) {
        uint8_t *bytes = (uint8_t*)[data bytes];
        uint8_t version = bytes[0];
        uint8_t rep = bytes[1];
        if(version == 0x05) {
            if (rep == 0x00) {
                // 第三步tcp代理转发
                [self socksFakeReply:pipeline];
            }
        }
    } else if (tag == TAG_READ_FROM_LOCAL) {
        // read data from local, send to remote
        /**
         *  存储本地解析后的目标服务器地址信息，等待Socks Server响应成功后
         *  再次将上面信息发送到Socks Server，获取目标服务器详细信息
         */
        pipeline.destinationData = data;
        [pipeline.remoteSocket writeData:data withTimeout:-1 tag:TAG_WRITE_TO_REMOTE];
        
    } else if (tag == TAG_READ_FROM_REMOTE) {
        // read data from remote, send to local
        [pipeline.localSocket writeData:data withTimeout:-1 tag:TAG_WRITE_TO_LOCAL];
    }
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag {
    // 获取当前 socket 连接对象
    SJXPipeline *pipeline = [self pipelineOfLocalSocket:sock] ? : [self pipelineOfRemoteSocket:sock];
    
    if (tag == TAG_LOCAL_CONNECT) {
        // socket 与本地连接
        [pipeline.localSocket readDataWithTimeout:-1 tag:TAG_GET_REQUEST];
    } else if (tag == TAG_WRITE_TO_LOCAL) {
        // write data to local
        [pipeline.remoteSocket readDataWithTimeout:-1 buffer:nil bufferOffset:0 maxLength:4096 tag:TAG_READ_FROM_REMOTE];
        [pipeline.localSocket readDataWithTimeout:-1 buffer:nil bufferOffset:0 maxLength:4096 tag:TAG_READ_FROM_LOCAL];
    } else if (tag == TAG_WRITE_TO_REMOTE) {
        // write data to remote
        [pipeline.remoteSocket readDataWithTimeout:-1 buffer:nil bufferOffset:0 maxLength:4096 tag:TAG_READ_FROM_REMOTE];
        [pipeline.localSocket readDataWithTimeout:-1 buffer:nil bufferOffset:0 maxLength:4096 tag:TAG_READ_FROM_LOCAL];
    } else if (tag == TAG_TCP_AUTH_FIRST) {
        // 第一步鉴权判断
        [pipeline.remoteSocket readDataWithTimeout:-1 tag:TAG_TCP_AUTH_FIRST];
    } else if (tag == TAG_TCP_AUTH_SECOND) {
        // 第二步鉴权判断
        [pipeline.remoteSocket readDataToLength:MODEL_LENGTH withTimeout:-1 tag:TAG_TCP_AUTH_SECOND];
    } else if(tag == TAG_TCP_SEND) {
        // tcp 转发
        [pipeline.remoteSocket readDataWithTimeout:-1 tag:TAG_TCP_SEND];
    }
    
}

#pragma mark - 设置Proxy Server协商方式
// 无需协商方式
- (void)setConsultMethodNoWithPipeline:(SJXPipeline *)pipeline
{
    char addr_to_send[ADDR_STR_LEN];
    int addr_len = 0;
    [self transformDataToProxyServer:pipeline addr:addr_to_send addr_len:addr_len];
    dispatch_queue_t queue = dispatch_queue_create("tcpRemoteSocketQueueName", NULL);
    GCDAsyncSocket *remoteSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:queue];
    pipeline.remoteSocket = remoteSocket;
    [remoteSocket connectToHost:_host onPort:_port error:nil];
    init_encryption(&(pipeline->sendEncryptionContext));
    init_encryption(&(pipeline->recvEncryptionContext));
    encrypt_buf(&(pipeline->sendEncryptionContext), addr_to_send, &addr_len);
    pipeline.addrData = [NSData dataWithBytes:addr_to_send length:addr_len];
}

// USERNAME/PASSWORD 协商方式
- (void)setConsultMethodUSRPSDWith:(SJXPipeline *)pipeline data:(NSData *)data {
    // 设置请求数据
    pipeline.requestData = data;
    if(!pipeline.remoteSocket) {
        // 设置 socket 与远端的连接
        dispatch_queue_t queue = dispatch_queue_create("tcpRemoteSocketQueueName", NULL);
        NSError *connectErr = nil;
        pipeline.remoteSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:queue];
        [pipeline.remoteSocket connectToHost:_host onPort:_port error:&connectErr];
    }
}

#pragma mark - 鉴权步骤
/**
 *  Sends the SOCKS5 open/handshake/authentication data, and starts reading the response.
 *  We attempt to gain anonymous access (no authentication).
 *
 *      +-----+-----------+---------+
 * NAME | VER | NMETHODS  | METHODS |
 *      +-----+-----------+---------+
 * SIZE |  1  |    1      | 1 - 255 |
 *      +-----+-----------+---------+
 *
 *  Note: Size is in bytes
 *
 *  Version    = 5 (for SOCKS5)
 *  NumMethods = 1
 *  Method     = 0 (No authentication, anonymous access)
 *  @param rmSocket remote Socket
 */
- (void)authFirstWithSocket:(GCDAsyncSocket *)rmSocket {
    // 第一步鉴权数据
    NSMutableData *authData = [NSMutableData dataWithCapacity:3];
    uint8_t ver[1] = {0x05};        // 版本号
    uint8_t nmethods[1] = {0x01};   // 认证方法数量
    uint8_t methods[1] = {0x02};    // 认证方法对应的编码列表
    [authData appendBytes:ver length:1];
    [authData appendBytes:nmethods length:1];
    [authData appendBytes:methods length:1];
    
    [rmSocket writeData:authData withTimeout:-1 tag:TAG_TCP_AUTH_FIRST];
}

/**
 *  读取与Proxy Server 协商返回的结果
 *
 *          +-----+--------+
 *    NAME  | VER | METHOD |
 *          +-----+--------+
 *    SIZE  |  1  |   1    |
 *          +-----+--------+
 *
 *  Note: Size is in bytes
 *
 *  Version = 5 (for SOCKS5)
 *  Method  = 0 (No authentication, anonymous access)
 *
 */
- (void)authFirstPassWithPipeline:(SJXPipeline *)pipeline data:(NSData *)data {
    uint8_t *bytes = (uint8_t*)[data bytes];
    uint8_t ver = bytes[0];
    uint8_t method = bytes[1];
    
    if (ver == 0x05) {
        // 对应的认证方法
        if (method == 0x02) {
#warning TODO : 根据自己的业务需求得到对应的 username 和 password
            NSString *username = [NSString string];
            NSString *password = [NSString string];
            // 第一步鉴权通过，进行第二步鉴权
            [self socksUserPassAuthWithPipeline:pipeline usr:username psd:password];
        }
    }
}

// 封装USERNAME/PASSWORD 为Package
/**
 *  封装username/password为package
 *        +-----+-------------+----------+-------------+------------
 *   NAME | VER | USERNAMELen | USERNAME | PASSWORDLEN |  PASSWORD  |
 *         +-----+------------+----------+-------------+------------
 *   SIZE |  1   |     1      |  1 - 255 |      1      |  1 - 255   |
 *         +-----+------------+----------+-------------+------------
 *
 */
- (void)socksUserPassAuthWithPipeline:(SJXPipeline *)pipeline usr:(NSString *)username psd:(NSString *)password
{
    NSData *usernameData = [username dataUsingEncoding:NSUTF8StringEncoding];
    NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];
    
    uint8_t usernameLength = (uint8_t)username.length;
    uint8_t passwordLength = (uint8_t)password.length;
    
    NSMutableData *authData = [NSMutableData dataWithCapacity:1+1+usernameLength + 1 + passwordLength];
    uint8_t version[1] = {0x01};
    [authData appendBytes:version length:1];
    [authData appendBytes:&usernameLength length:1];
    [authData appendBytes:usernameData.bytes length:usernameLength];
    [authData appendBytes:&passwordLength length:1];
    [authData appendBytes:passwordData.bytes length:passwordLength];
    
    [pipeline.remoteSocket writeData:authData withTimeout:-1 tag:TAG_TCP_AUTH_SECOND];
}

// USERNAME/PASSWORD 登录验证结果
- (void)authSecondPassWithPipeline:(SJXPipeline *)pipeline data:(NSData *)data {
    // 判断返回的数据长度是否正常
    if (data.length == MODEL_LENGTH) {
        uint8_t *bytes = (uint8_t*)[data bytes];
        UInt8 ver = bytes[0];
        UInt8 status = bytes[1];
        
        if (ver == 0x01) {
            if (status == 0x00) {
                [self.tcpClientDelegate tcpSocketDidFinishLoad:pipeline.remoteSocket];
                
                // 第二步鉴权通过，进行第三步tcp请求
                char addr_to_send[ADDR_STR_LEN];
                int addr_len = 0;
                addr_len = [self transformDataToProxyServer:pipeline addr:addr_to_send addr_len:addr_len];
                [pipeline.remoteSocket writeData:pipeline.requestData withTimeout:-1 tag:TAG_TCP_SEND];
                pipeline.addrData = [NSData dataWithBytes:addr_to_send length:addr_len];
            }
        }
    }
}

#pragma mark - 请求转发/fade reply
/**
 *  根据destination host & prot 获取的data，转发Proxy Server
 */
- (int)transformDataToProxyServer:(SJXPipeline *)pipeline addr:(char [ADDR_STR_LEN])addr_to_send addr_len:(int)addr_len {
    // transform data
    struct socks5_request *request = (struct socks5_request *)pipeline.requestData.bytes;
    if (request->cmd != SOCKS_CMD_CONNECT) {
        struct socks5_response response;
        response.ver = SOCKS_VERSION;
        response.rep = SOCKS_CMD_NOT_SUPPORTED;
        response.rsv = 0;
        response.atyp = SOCKS_IPV4;
        char *send_buf = (char *)&response;
        [pipeline.localSocket writeData:[NSData dataWithBytes:send_buf length:4] withTimeout:-1 tag:1];
        [pipeline disconnect];
        return -1;
    }
    
    addr_to_send[addr_len++] = request->atyp;
    char addr_str[ADDR_STR_LEN];
    // get remote addr and port
    if (request->atyp == SOCKS_IPV4) {
        // IP V4
        size_t in_addr_len = sizeof(struct in_addr);
        memcpy(addr_to_send + addr_len, pipeline.requestData.bytes + 4, in_addr_len + 2);
        addr_len += in_addr_len + 2;
        
        // now get it back and print it
        inet_ntop(AF_INET, pipeline.requestData.bytes + 4, addr_str, ADDR_STR_LEN);
    } else if (request->atyp == SOCKS_DOMAIN) {
        // Domain name
        unsigned char name_len = *(unsigned char *)(pipeline.requestData.bytes + 4);
        addr_to_send[addr_len++] = name_len;
        memcpy(addr_to_send + addr_len, pipeline.requestData.bytes + 4 + 1, name_len);
        memcpy(addr_str, pipeline.requestData.bytes + 4 + 1, name_len);
        addr_str[name_len] = '\0';
        addr_len += name_len;
        
        // get port
        unsigned char v1 = *(unsigned char *)(pipeline.requestData.bytes + 4 + 1 + name_len);
        unsigned char v2 = *(unsigned char *)(pipeline.requestData.bytes + 4 + 1 + name_len + 1);
        addr_to_send[addr_len++] = v1;
        addr_to_send[addr_len++] = v2;
    } else {
        [pipeline disconnect];
        return -1;
    }
    return addr_len;
}

/**
 *  local socket 回调
 *
 *  @param pipeline pipeline
 */
- (void)socksFakeReply:(SJXPipeline *)pipeline {
    // Fake reply
    struct socks5_response response;
    response.ver = SOCKS_VERSION;
    response.rep = 0;
    response.rsv = 0;
    response.atyp = SOCKS_IPV4;
    
    struct in_addr sin_addr;
    inet_aton("0.0.0.0", &sin_addr);
    
    int reply_size = 4 + sizeof(struct in_addr) + sizeof(unsigned short);
    char *replayBytes = (char *)malloc(reply_size);
    
    memcpy(replayBytes, &response, 4);
    memcpy(replayBytes + 4, &sin_addr, sizeof(struct in_addr));
    *((unsigned short *)(replayBytes + 4 + sizeof(struct in_addr)))
    = (unsigned short) htons(atoi("22"));
    NSLog(@"socksFakeReply -----tcp----- data:%@, len:%d", [NSData dataWithBytes:replayBytes length:reply_size], reply_size);
    [pipeline.localSocket writeData:[NSData dataWithBytes:replayBytes length:reply_size] withTimeout:-1 tag:TAG_WRITE_TO_LOCAL];
    free(replayBytes);
}

#pragma mark - EVSocksClientError
- (NSError *)errorWithMessage:(NSString *)errMsg {
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    return [NSError errorWithDomain:SJXTCPSocksClientErrorDomain code:0 userInfo:userInfo];
}

- (void)errorDelegateWithPipeline:(SJXPipeline *)pipeline errorTag:(uint8_t)errorTag errorMessage:(NSString *)errorMessage {
    [pipeline disconnect];
    NSError *error = [self errorWithMessage:errorMessage];
    GCDAsyncSocket *socket = pipeline.remoteSocket ? : pipeline.localSocket;
    [self.tcpClientDelegate tcpSocket:socket didFailWithError:error errorTag:errorTag];
    return;
}

#pragma mark - Dealloc
- (void)dealloc
{
    _serverSocket = nil;
    _pipelines = nil;
    _host = nil;
}

@end
