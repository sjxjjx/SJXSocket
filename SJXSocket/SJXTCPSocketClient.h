//
//  SJXTCPSocketClient.h
//  TCPDemo
//
//  Created by shapp on 2018/1/26.
//  Copyright © 2018年 shapp. All rights reserved.
//
#import <Foundation/Foundation.h>
@class GCDAsyncSocket;

// 协商方式
typedef NS_ENUM(NSInteger, SJXTCPSocksClientConsultMethod) {
    SJXTCPSocksClientConsultMethodNO = 0,   // 无需协商方式
    SJXTCPSocksClientConsultMethodGSSAPI,   // GSSAPI   (暂不支持)
    SJXTCPSocksClientConsultMethodUSRPSD,   // USERNAME/PASSWORD
};

#pragma mark - <SJXTCPSocksClientDelegate>
@protocol SJXTCPSocksClientDelegate <NSObject>
/**
 *  tcp代理失败时，调用此方法
 *
 *  @param socket       请求验证的socket Object
 *  @param error        错误提示
 *  @param errorTag     错误值
 */
- (void)tcpSocket:(GCDAsyncSocket *)socket didFailWithError:(NSError *)error errorTag:(int)errorTag;
/**
 *  tcp代理成功时，调用此方法
 *
 *  @param socket 请求验证的socket Object
 */
- (void)tcpSocketDidFinishLoad:(GCDAsyncSocket *)socket;
@end


@interface SJXTCPSocketClient : NSURLProtocol

@property (nonatomic, assign) SJXTCPSocksClientConsultMethod consultMethod;   // 协商方式
@property (nonatomic, readonly) NSString *host;     // tcp 代理地址
@property (nonatomic, readonly) NSInteger port;     // tcp 代理端口
@property (nonatomic, weak) id<SJXTCPSocksClientDelegate> tcpClientDelegate;

/**
 *  单例
 *  @return SJXTCPSocketClient
 */
+ (instancetype)shareTcpScoketClient;

/**
 *  设置 tcp 代理参数
 *  @param host       代理地址
 *  @param port       代理端口
 */
- (void)setTcpHost:(NSString *)host port:(NSInteger)port;

/**
 *  监听本地端口
 *  @param localPort 本地端口
 */
- (BOOL)startWithLocalPort:(NSInteger)localPort;

/**
 *  停止代理
 */
- (void)stop;

/**
 *  判断是否已经连接代理服务器
 */
- (BOOL)isConnected;

@end
