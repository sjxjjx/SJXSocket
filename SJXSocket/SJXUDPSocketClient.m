//
//  SJXUDPSocketClient.m
//  SJXSocket
//
//  Created by shapp on 2018/1/26.
//  Copyright © 2018年 shapp. All rights reserved.
//

#define TAG_AUTH_FIRST          1001
#define TAG_AUTH_SECOND         1002
#define TAG_UDP_CONNECT         2001
#define TAG_UDP_SEND            2002
#define ADDR_STR_LEN            512         //!< url length

#define ERROR_UDP_BIND_U        50001
#define ERROR_UDP_BIND_T        50002
#define ERROR_UDP_DISCONNECT    50003

#import "SJXUDPSocketClient.h"
#import "GCDAsyncUdpSocket.h"
#import "GCDAsyncSocket.h"
#include "socks5.h"
#include <arpa/inet.h>
#import "NSString+Extension.h"

#pragma mark - <SJXUDPPipeline>
@interface SJXUDPPipeline : NSObject
@property (nonatomic, strong) GCDAsyncSocket *tcpRemoteSocket;

@property (nonatomic, copy) NSString *  udpLocalIp;
@property (nonatomic, assign) uint16_t  udpLocalPort;
@property (nonatomic, copy) NSString *  udpProxyIp;
@property (nonatomic, assign) uint16_t  udpProxyPort;
@property (nonatomic, copy) NSString *  udpRemoteIp;
@property (nonatomic, assign) uint16_t  udpRemotePort;

@property (nonatomic, strong) NSData *  udpSessionIDData;
@property (nonatomic, strong) NSData *  udpRequestData;

- (void)disconnect;
@end

@implementation SJXUDPPipeline
- (void)disconnect {
    [self.tcpRemoteSocket disconnectAfterReadingAndWriting];
}

@end

#pragma mark - <SJXUDPSocketClient>
@interface SJXUDPSocketClient () <GCDAsyncSocketDelegate, GCDAsyncUdpSocketDelegate>
{
    dispatch_queue_t _tcpSocketQueue;
    
    dispatch_queue_t _udpSocketQueue;
    GCDAsyncUdpSocket * _udpLocalSocket;
    GCDAsyncUdpSocket * _udpRemoteSocket;
    
    NSMutableArray * _pipelines;      // 所有连接Socks Server 的Object
    NSString *_host;
    NSInteger _port;
}

@end

@implementation SJXUDPSocketClient

@synthesize host = _host;
@synthesize port = _port;

#pragma mark - 根据 Socket,查找 Super Object
- (SJXUDPPipeline *)pipelineOfRemoteSocket:(GCDAsyncSocket *)remoteSocket {
    __block SJXUDPPipeline *ret;
    [_pipelines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SJXUDPPipeline *pipeline = obj;
        if (pipeline.tcpRemoteSocket == remoteSocket) {
            ret = pipeline;
        }
    }];
    return ret;
}

- (SJXUDPPipeline *)pipelineWithLocalIp:(NSString *)localIp localPort:(uint16_t)localPort remoteIp:(NSString *)remoteIp remotePort:(uint16_t)remotePort {
    __block SJXUDPPipeline *ret;
    [_pipelines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SJXUDPPipeline *pipeline = obj;
        if ([pipeline.udpLocalIp isEqualToString:localIp] && [pipeline.udpRemoteIp isEqualToString:remoteIp] && pipeline.udpLocalPort == localPort && pipeline.udpRemotePort == remotePort) {
            ret = pipeline;
        }
    }];
    return ret;
}

- (SJXUDPPipeline *)pipelineWithSessionIdData:(NSData *)sessionIdData {
    __block SJXUDPPipeline *ret;
    [_pipelines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SJXUDPPipeline *pipeline = obj;
        if ([pipeline.udpSessionIDData isEqual:sessionIdData]) {
            ret = pipeline;
        }
    }];
    return ret;
}

#pragma mark - 外部调用接口
+ (instancetype)shareUdpSocketClient {
    static SJXUDPSocketClient * _udpClient;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _udpClient = [[SJXUDPSocketClient alloc] init];
    });
    return _udpClient;
}

- (void)setUdpHost:(NSString *)host port:(NSInteger)port {
    _host = [host copy];
    _port = port;
}

// 开启监听本地端口和远端端口
- (BOOL)startWithUdpLocalPort:(uint16_t)udpLocalPort udpRemotePort:(uint16_t)udpRemotePort {
    [self stop];
    
    _pipelines = [[NSMutableArray alloc] init];
    
    _udpSocketQueue = dispatch_queue_create("udpSocketQueueName", NULL);
    _udpLocalSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:_udpSocketQueue];
    NSError *error;
    // 绑定udp本地端口
    [_udpLocalSocket bindToPort:udpLocalPort error:&error];
    [_udpLocalSocket enableBroadcast:YES error:&error];
    if (error) {
        [self.udpClientDelegate clientWithUdpSocket:_udpLocalSocket didFailureWithError:error errorTag:ERROR_UDP_BIND_U];
        return NO;
    } else {
        // 开始接收消息
        [_udpLocalSocket beginReceiving:&error];
    }
    
    // 绑定udp远端端口
    _udpRemoteSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:_udpSocketQueue];
    [_udpRemoteSocket bindToPort:udpRemotePort error:&error];
    [_udpRemoteSocket enableBroadcast:YES error:&error];
    if (error) {
        [self.udpClientDelegate clientWithUdpSocket:_udpRemoteSocket didFailureWithError:error errorTag:ERROR_UDP_BIND_U];
        return NO;
    } else {
        // 开始接收消息
        [_udpRemoteSocket beginReceiving:&error];
    }
    
    return YES;
}

// 停止代理
- (void)stop {
    [_udpLocalSocket closeAfterSending];
    [_udpRemoteSocket closeAfterSending];
    
    NSArray *ps = [NSArray arrayWithArray:_pipelines];
    [ps enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SJXUDPPipeline *pipeline = obj;
        [pipeline.tcpRemoteSocket disconnect];
    }];
    
    _udpLocalSocket = nil;
    _udpRemoteSocket = nil;
}

// 进行 USERNAME/PASSWORD 协商鉴权
- (void)setConsultMethodUSRPSDWithPipeline:(SJXUDPPipeline *)pipeline data:(NSData *)data {
    NSLog(@"setConsultMethodUSRPSDWith -----udp----- data : %@", data);
    // store request data
    pipeline.udpRequestData = data;
    if(!pipeline.tcpRemoteSocket) {
        NSError *connectErr = nil;
        pipeline.tcpRemoteSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:_tcpSocketQueue];
        // 连接代理服务器
        [pipeline.tcpRemoteSocket connectToHost:_host onPort:_port error:&connectErr];
    }
}

#pragma mark - 鉴权过程
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
 *  NumMethods = 1  目前 只支持 1 种认证 方法：0x81，所以这个值为 1
 *  Method     = 81 目前只支持 1 种 认证方法：0x81
 *  @param rmSocket remote Socket
 */
- (void)authFirstConnectWithSocket:(GCDAsyncSocket *)rmSocket {
    NSMutableData *authData = [NSMutableData dataWithCapacity:3];
    uint8_t ver[1] = {0x05};        // 版本号
    uint8_t nmethods[1] = {0x01};   // 认证方法数量
    uint8_t methods[1] = {0x02};    // 认证方法对应的编码列表
    [authData appendBytes:ver length:1];
    [authData appendBytes:nmethods length:1];
    [authData appendBytes:methods length:1];
    
    [rmSocket writeData:authData withTimeout:-1 tag:TAG_AUTH_FIRST];
}

// 鉴权第一步成功
- (void)authFirstPassWithPileline:(SJXUDPPipeline *)pipeline data:(NSData *)data {
    uint8_t *bytes = (uint8_t*)[data bytes];
    uint8_t version = bytes[0];
    uint8_t method = bytes[1];
    if (version == 0x05) {
        if (method == 0x02) {
            [self authFirstPassMethodWithPileline:pipeline];
        }
    }
}

- (void)authFirstPassMethodWithPileline:(SJXUDPPipeline *)pipeline {
    [self.udpClientDelegate clientFinishWithTcpSocket:pipeline.tcpRemoteSocket];
#warning TODO : 根据自己的业务需求得到对应的 username 和 password
    NSString *username = [NSString string];
    NSString *password = [NSString string];
    
    [self authSecondConnectWithSocket:pipeline.tcpRemoteSocket usr:username psd:password];
}

/**
 *  封装username/password为package
 *        +-----+-------------+----------+-------------+------------
 *   NAME | VER | USERNAMELen | USERNAME | PASSWORDLEN |  PASSWORD  |
 *         +-----+------------+----------+-------------+------------
 *   SIZE |  1   |     1      |  1 - 255 |      1      |  1 - 255   |
 *         +-----+------------+----------+-------------+------------
 *
 *  @param rmSocket remote socket
 */
- (void)authSecondConnectWithSocket:(GCDAsyncSocket *)rmSocket usr:(NSString *)username psd:(NSString *)password {
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
    
    [rmSocket writeData:authData withTimeout:-1 tag:TAG_AUTH_SECOND];
}

// 鉴权第二步成功
- (void)authSecondPassWithPipeline:(SJXUDPPipeline *)pipeline data:(NSData *)data {
    uint8_t *bytes = (uint8_t*)[data bytes];
    uint8_t ver = bytes[0];
    uint8_t status = bytes[1];
    
    if (ver == 0x01) {
        if (status == 0x00) {
            [self.udpClientDelegate clientFinishWithTcpSocket:pipeline.tcpRemoteSocket];
            // 进行 udp 连接
            [self socksUDPAuthWithPipeline:pipeline];
        }
    }
}

// UDP连接请求
//      +-----+-----+-----+------+------+------+
// NAME | VER | CMD | RSV | ATYP | ADDR | PORT |
//      +-----+-----+-----+------+------+------+
// SIZE |  1  |  1  |  1  |  1   | var  |  2   |
//      +-----+-----+-----+------+------+------+
//
- (void)socksUDPAuthWithPipeline:(SJXUDPPipeline *)pipeline {
    // 设置本机的ip地址和端口
    struct sockaddr_in serv_addr = [self getAddressWithIp:[NSString getIPAddress:YES] port:pipeline.udpLocalPort];
    NSData *localIPData = [NSData dataWithBytes:&serv_addr.sin_addr.s_addr length:4];
    NSData *localPortData = [NSData dataWithBytes:&serv_addr.sin_port length:2];
    
    NSMutableData *udpConnectData = [NSMutableData dataWithCapacity:1 + 1 + 1 + 1 + localIPData.length + localPortData.length];
    
    uint8_t ver[1] = {0x05};        // 版本号
    [udpConnectData appendBytes:ver length:1];
    
    // 请求类型
    uint8_t cmd[1] = {0x04};    // udp
    [udpConnectData appendBytes:cmd length:1];
    
    uint8_t rsv[1] = {0x00};        // 保留，固定值
    uint8_t atyp[1] = {0x01};       // 地址类型 : 0x01 IPV4     0x03 域名     0x04 IPV6(保留)
    
    [udpConnectData appendBytes:rsv length:1];
    [udpConnectData appendBytes:atyp length:1];
    [udpConnectData appendBytes:localIPData.bytes length:localIPData.length];
    [udpConnectData appendBytes:localPortData.bytes length:localPortData.length];
    
    [pipeline.tcpRemoteSocket writeData:udpConnectData withTimeout:-1 tag:TAG_UDP_CONNECT];
}

// UDP连接判断
- (void)udpConnectPassWithPipeline:(SJXUDPPipeline *)pipeline data:(NSData *)data {
    uint8_t *bytes = (uint8_t*)[data bytes];
    uint8_t ver = bytes[0];
    uint8_t rep = bytes[1];
    
    if (ver == 0x05) {
        if (rep == 0x00) {
            uint8_t *bytes = (uint8_t*)[data bytes];
            uint8_t atyp = bytes[3];
            if (atyp == 0x01) {
                // 发送消息
                [self sendUDPMessageWithPipeline:pipeline data:data isNeedAuth:YES];
            }
        }
    }
}

// 发送udp请求数据
- (void)sendUDPMessageWithPipeline:(SJXUDPPipeline *)pipeline data:(NSData *)data isNeedAuth:(BOOL)isNeedAuth {
    // 获取转发的数据、目标地址、端口
    NSData *sessionIDData = [NSData data];
    NSData *sendData = [NSData data];
    NSString *dstIp = [NSString string];
    NSInteger dstPort = 0;
    
    // 需要鉴权的情况
    if (isNeedAuth) {
        // 获取到代理服务器分配的地址和端口、sessionID
        NSData *proxyIpData = [data subdataWithRange:NSMakeRange(4, 4)];
        NSData *proxyPortData = [data subdataWithRange:NSMakeRange(8, 2)];
        sessionIDData = [data subdataWithRange:NSMakeRange(10, 8)];
        
        char proxyIpBuff[32] = {};
        inet_ntop(AF_INET, proxyIpData.bytes, proxyIpBuff, 32);
        NSString *proxyIpStr = [NSString stringWithCString:proxyIpBuff encoding:NSUTF8StringEncoding];
        
        int tempProxyProt;
        [proxyPortData getBytes:&tempProxyProt length: sizeof(tempProxyProt)];
        uint16_t proxyPort = ntohs(tempProxyProt);
        
        // 保存代理地址信息
        pipeline.udpProxyIp = proxyIpStr;
        pipeline.udpProxyPort = proxyPort;
        pipeline.udpSessionIDData = sessionIDData;
        
        // 获取转发的数据、目标地址、端口
        sendData = pipeline.udpRequestData;
        dstIp = pipeline.udpRemoteIp;
        dstPort = pipeline.udpRemotePort;
    } else {
        // 获取转发的数据、目标地址、端口
        sendData = data;
        sessionIDData = pipeline.udpSessionIDData;
        dstIp = pipeline.udpRemoteIp;
        dstPort = pipeline.udpRemotePort;
    }
    
    struct sockaddr_in udp_addr = [self getAddressWithIp:dstIp port:dstPort];
    NSData *dstIpData = [NSData dataWithBytes:&udp_addr.sin_addr.s_addr length:4];
    NSData *dstPortData = [NSData dataWithBytes:&udp_addr.sin_port length:2];
    
    NSMutableData *sendUDPData = [NSMutableData dataWithCapacity:2 + 1 + 1 + dstIpData.length + dstPortData.length + sessionIDData.length + sendData.length];
    uint16_t rsv[1] = {0x0000};     // 保留
    uint8_t frag[1] = {0x00};       // 分片序号     目前只支持 0x00，也就是 UDP 数据包不分片
    uint8_t atyp[1] = {0x01};       // 地址类型 : 0x01 IPV4     0x03 域名     0x04 IPV6(保留)
    
    [sendUDPData appendBytes:rsv length:2];
    [sendUDPData appendBytes:frag length:1];
    [sendUDPData appendBytes:atyp length:1];
    [sendUDPData appendBytes:dstIpData.bytes length:dstIpData.length];
    [sendUDPData appendBytes:dstPortData.bytes length:dstPortData.length];
    [sendUDPData appendBytes:sessionIDData.bytes length:sessionIDData.length];
    [sendUDPData appendBytes:sendData.bytes length:sendData.length];
    
    // 向代理服务器分配的地址发送数据
    [_udpRemoteSocket sendData:sendUDPData toHost:pipeline.udpProxyIp port:pipeline.udpProxyPort withTimeout:-1 tag:TAG_UDP_SEND];
}

#pragma mark - GCDAsyncSocketDelegate
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    SJXUDPPipeline *pipeline = [self pipelineOfRemoteSocket:sock];
    if (!pipeline) return;
    
    if (tag == TAG_AUTH_FIRST) {
        // 第一步鉴权判断
        [self authFirstPassWithPileline:pipeline data:data];
    } else if (tag == TAG_AUTH_SECOND) {
        // 第二步鉴权判断
        [self authSecondPassWithPipeline:pipeline data:data];
    } else if (tag == TAG_UDP_CONNECT) {
        // UDP连接判断
        [self udpConnectPassWithPipeline:pipeline data:data];
    }
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag {
    SJXUDPPipeline *pipeline = [self pipelineOfRemoteSocket:sock];
    
    if (tag == TAG_AUTH_FIRST) {
        [pipeline.tcpRemoteSocket readDataWithTimeout:-1 tag:TAG_AUTH_FIRST];
    } else if (tag == TAG_AUTH_SECOND) {
        [pipeline.tcpRemoteSocket readDataWithTimeout:-1 tag:TAG_AUTH_SECOND];
    } else if (tag == TAG_UDP_CONNECT) {
        [pipeline.tcpRemoteSocket readDataWithTimeout:-1 tag:TAG_UDP_CONNECT];
    }
}

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    SJXUDPPipeline *pipeline = [self pipelineOfRemoteSocket:sock];
    if (pipeline) {
        // 进行鉴权
        [self authFirstConnectWithSocket:pipeline.tcpRemoteSocket];
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    [self.udpClientDelegate clientWithTcpSocket:sock didFailureWithError:err errorTag:ERROR_UDP_DISCONNECT];
    SJXUDPPipeline *pipeline;
    pipeline = [self pipelineOfRemoteSocket:sock];
    
    if (pipeline) {
        if (pipeline.tcpRemoteSocket.isDisconnected) {
            [_pipelines removeObject:pipeline];
        } else {
            [pipeline.tcpRemoteSocket disconnectAfterReadingAndWriting];
        }
        return;
    }
}

#pragma mark - <GCDAsyncUdpSocketDelegate>
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(nullable id)filterContext {
    
    // 获取来源 ip和端口
    NSString* fromHost;
    uint16_t fromPort;
    [GCDAsyncUdpSocket getHost:&fromHost port:&fromPort fromAddress:address];
    
    if ([fromHost containsString:@"127.0.0.1"]) {
        // 从本地代理接收数据，转发到远端代理服务器
#warning TODO : 根据需要进行修改
        /*
         1. 当客户端发起 UDP 请求时进行拦截，将 目标ip 和 port 拼接到发送信息后面
         2. 客户端将修改后的数据转发到本地 UDP 代理
         3. 本地 UDP 代理接收到响应时，这里进行解析
         */
        // 获取需要发送的信息、目标ip、目标port
        NSData *dstData = [data subdataWithRange:NSMakeRange(0, data.length - 6)];
        NSData *dstHostData = [data subdataWithRange:NSMakeRange(data.length - 6, 4)];
        NSData *dstPortData = [data subdataWithRange:NSMakeRange(data.length - 2, 2)];
        // 目标地址ip
        char dstIP[32];
        inet_ntop(AF_INET,  [dstHostData bytes], dstIP, sizeof(dstIP));
        NSString* dstIpStr = [NSString stringWithFormat:@"%s", dstIP];
        // 目标地址端口
        uint16_t dstPort;
        [dstPortData getBytes:&dstPort length:sizeof(dstPort)];
        dstPort = ntohs(dstPort);
        
        // 获取本地 UDP 代理对象
        SJXUDPPipeline *pipeline = [self pipelineWithLocalIp:fromHost localPort:fromPort remoteIp:dstIpStr remotePort:dstPort];
        
        if (!pipeline) {
            // 通过 TCP 连接与远端代理进行鉴权
            pipeline = [[SJXUDPPipeline alloc] init];
            pipeline.udpRequestData = dstData;
            pipeline.udpLocalIp = fromHost;
            pipeline.udpLocalPort = fromPort;
            pipeline.udpRemoteIp = dstIpStr;
            pipeline.udpRemotePort = dstPort;
            [self connectTcpRemoteSocketWithPipeline:pipeline];
            [_pipelines addObject:pipeline];
        } else {
            if (!pipeline.tcpRemoteSocket ||
                pipeline.udpProxyIp == nil ||
                pipeline.udpProxyIp.length == 0 ||
                pipeline.udpProxyPort <= 0) {
                
                [_pipelines removeObject:pipeline];
                // 与远端代理重新进行鉴权
                pipeline = [[SJXUDPPipeline alloc] init];
                pipeline.udpRequestData = dstData;
                pipeline.udpLocalIp = fromHost;
                pipeline.udpLocalPort = fromPort;
                pipeline.udpRemoteIp = dstIpStr;
                pipeline.udpRemotePort = dstPort;
                [self connectTcpRemoteSocketWithPipeline:pipeline];
                [_pipelines addObject:pipeline];
            } else {
                // 鉴权通过后会分配一个 IP 和 UDP 端口，向远端代理服务器分配的地址发送数据
                [self sendUDPMessageWithPipeline:pipeline data:dstData isNeedAuth:NO];
            }
        }
    } else {
        // 从远端代理服务器接收到数据，转发到本地代理
        NSData *sessionIDData = [data subdataWithRange:NSMakeRange(10, 8)];
        // 根据会话标识获取代理对象
        SJXUDPPipeline *pipeline = [self pipelineWithSessionIdData:sessionIDData];
        if (pipeline) {
            NSData * receiveData = [data subdataWithRange:NSMakeRange(18, data.length - 18)];
            [_udpLocalSocket sendData:receiveData toHost:pipeline.udpLocalIp port:pipeline.udpLocalPort withTimeout:-1 tag:0];
        }
    }
}

// tcp连接进行鉴权
- (void)connectTcpRemoteSocketWithPipeline:(SJXUDPPipeline *)pipeline {
    if (!_tcpSocketQueue) {
        _tcpSocketQueue = dispatch_queue_create("tcpSocketQueueName", NULL);
    }
    pipeline.tcpRemoteSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:_tcpSocketQueue];
    NSError *connectErr = nil;
    [pipeline.tcpRemoteSocket connectToHost:_host onPort:_port error:&connectErr];
    if (connectErr) {
        [self.udpClientDelegate clientWithTcpSocket:pipeline.tcpRemoteSocket didFailureWithError:connectErr errorTag:ERROR_UDP_BIND_T];
        return;
    }
}

#pragma mark - <other>
- (struct sockaddr_in)getAddressWithIp:(NSString *)ipString port:(uint16_t)port
{
    // 设置本机的ip地址和端口
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr([ipString UTF8String]);
    addr.sin_port = htons(port);
    
    return addr;
}

NSString *const ICGUDPClientErrorDomain = @"ICGUDPClientErrorDomain";
- (NSError *)errorWithUdpMessage:(NSString *)errMsg {
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    return [NSError errorWithDomain:ICGUDPClientErrorDomain code:0 userInfo:userInfo];
}
- (void)delegateWithPipeline:(SJXUDPPipeline *)pipeline errorTag:(uint8_t)errorTag errorMessage:(NSString *)errorMessage {
    [pipeline disconnect];
    NSError *error = [self errorWithUdpMessage:errorMessage];
    [self.udpClientDelegate clientWithTcpSocket:pipeline.tcpRemoteSocket didFailureWithError:error errorTag:errorTag];
    return;
}

#pragma mark - Dealloc
- (void)dealloc {
    _udpLocalSocket = nil;
    _udpRemoteSocket = nil;
    _pipelines = nil;
    _host = nil;
}

@end
