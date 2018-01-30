//
//  SJXUDPSocketClient.h
//  SJXSocket
//
//  Created by shapp on 2018/1/26.
//  Copyright © 2018年 shapp. All rights reserved.
//

#import <Foundation/Foundation.h>
@class GCDAsyncUdpSocket;
@class GCDAsyncSocket;

#pragma mark - <SJXUDPSocksClientDelegate>
/**
 *   代理方法，提供成功或失败时调用方法
 */
@protocol SJXUDPSocksClientDelegate <NSObject>
/**
 *  TCP连接失败时，会调用此方法
 *  @param socket 请求验证的socket Object
 *  @param error  错误提示
 */
- (void)clientWithTcpSocket:(GCDAsyncSocket *)socket didFailureWithError:(NSError *)error errorTag:(int)errorTag;
/**
 *  UDP连接失败时，会调用此方法
 *  @param socket 请求验证的socket Object
 *  @param error  错误提示
 */
- (void)clientWithUdpSocket:(GCDAsyncUdpSocket *)socket didFailureWithError:(NSError *)error errorTag:(int)errorTag;
/**
 *  TCP连接成功时，会调用此方法
 *  @param socket 请求验证的socket Object
 */
- (void)clientFinishWithTcpSocket:(GCDAsyncSocket *)socket;
/**
 *  UDP连接成功时，会调用此方法
 *  @param socket 请求验证的socket Object
 */
- (void)clientFinishWithUdpSocket:(GCDAsyncUdpSocket *)socket;
@end

@interface SJXUDPSocketClient : NSURLProtocol

@property (nonatomic, readonly) NSString *host;         // 代理服务器地址
@property (nonatomic, readonly) NSInteger port;         // 代理服务器端口
@property (nonatomic, weak) id <SJXUDPSocksClientDelegate> udpClientDelegate;

/**
 *  单例
 *  @return SJXUDPSocketClient
 */
+ (instancetype)shareUdpSocketClient;

/**
 *  设置代理地址
 *  @param host       代理服务器地址
 *  @param port       代理服务器端口
 */
- (void)setUdpHost:(NSString *)host port:(NSInteger)port;

/**
 *  监听本地端口
 *  @param udpLocalPort  本地local
 *  @param udpRemotePort 本地remote
 */
- (BOOL)startWithUdpLocalPort:(uint16_t)udpLocalPort udpRemotePort:(uint16_t)udpRemotePort;

/**
 *  停止代理
 */
- (void)stop;

@end
