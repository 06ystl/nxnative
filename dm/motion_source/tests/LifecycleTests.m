#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import "ViewController.h"
#import "MotionNetworkCheck.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>

// Exercise the real UIKit controller and real UDP sockets on Mac Catalyst.
// Sensor hardware is checked on the phone; no game process participates here.
@interface LifecycleTests : XCTestCase
@property ViewController *controller;
@property uint16_t port;
@end
@implementation LifecycleTests
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(),block);
}
- (BOOL)isRunning {
    __block BOOL running;
    [self onMain:^{ running=[[self.controller valueForKey:@"serverStarted"] boolValue]; }];
    return running;
}
- (void)setUp {
    [super setUp];
    int fd=socket(AF_INET,SOCK_DGRAM,0);
    struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    XCTAssertEqual(bind(fd,(void *)&address,sizeof address),0);
    socklen_t size=sizeof address;getsockname(fd,(void *)&address,&size);self.port=ntohs(address.sin_port);close(fd);
    [self onMain:^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if ([scene isKindOfClass:UIWindowScene.class]) {
                UIWindowScene *windowScene=(UIWindowScene *)scene;
                if (windowScene.windows.firstObject.rootViewController)
                    self.controller=(ViewController *)windowScene.windows.firstObject.rootViewController;
            }
        XCTAssertTrue([self.controller isKindOfClass:ViewController.class]);
        [self.controller loadViewIfNeeded];
        [self.controller stopServer];
        self.controller.portTextField.text=[NSString stringWithFormat:@"%u",self.port];
        [self.controller setPortPressed:nil];
    }];
}
- (void)tearDown {
    [self onMain:^{ [self.controller stopServer]; }];
    [super tearDown];
}
- (void)checkVersionResponse {
    XCTestExpectation *received=[self expectationWithDescription:@"actual DSU version response"];
    unsigned port=self.port;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        // Independent protocol fixture, CRC generated with Python zlib.
        const uint8_t request[]={0x44,0x53,0x55,0x43,0xe9,0x03,0x04,0x00,0xc9,0xbc,0x7b,0xb7,0x78,0x56,0x34,0x12,0,0,0x10,0};
        int fd=socket(AF_INET,SOCK_DGRAM,0);
        struct timeval timeout={.tv_sec=1};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
        struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_port=htons(port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        // DSU is UDP: renew once a second, as the Mac client does, rather than
        // requiring delivery of the first datagram on a newly created socket.
        uint8_t response[128];ssize_t n=-1;
        for(int attempt=0;attempt<3 && n<0;attempt++) {
            XCTAssertEqual(sendto(fd,request,sizeof request,0,(void *)&address,sizeof address),sizeof request);
            n=recv(fd,response,sizeof response,0);
        }
        XCTAssertEqual(n,24);if(n==24) {
            XCTAssertEqual(memcmp(response,"DSUS",4),0);
            XCTAssertEqual(response[20],0xe9);XCTAssertEqual(response[21],3);
        }
        close(fd);[received fulfill];
    });
    [self waitForExpectations:@[received] timeout:4];
}
- (void)testRepeatedStartStopReusesTheSamePort {
    for(int i=0;i<5;i++) {
        [self onMain:^{ [self.controller startServer]; }];
        XCTAssertTrue(self.isRunning);[self checkVersionResponse];
        [self onMain:^{
            XCTAssertEqualObjects(self.controller.startstopServerButton.configuration.title,@"Stop Server");
            [self.controller stopServer];
            XCTAssertEqualObjects(self.controller.startstopServerButton.configuration.title,@"Start Server");
            XCTAssertTrue(self.controller.startstopServerButton.enabled);
        }];
        XCTAssertFalse(self.isRunning);
    }
}
- (void)testSuspensionAndLateCloseCannotEraseTheNewServer {
    [self onMain:^{ [self.controller startServer]; }];
    __block GCDAsyncUdpSocket *old;
    [self onMain:^{
        old=[self.controller valueForKey:@"socket"];
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    }];
    XCTAssertFalse(self.isRunning);
    [self onMain:^{
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    }];
    XCTAssertTrue(self.isRunning);
    [self onMain:^{ [self.controller udpSocketDidClose:old withError:nil]; }];
    XCTAssertTrue(self.isRunning);[self checkVersionResponse];
}
- (void)testUnexpectedSocketClosureRecoversOnTheSamePort {
    [self onMain:^{ [self.controller startServer]; }];
    __block GCDAsyncUdpSocket *old;
    [self onMain:^{ old=[self.controller valueForKey:@"socket"];[old close]; }];
    NSPredicate *recovered=[NSPredicate predicateWithBlock:^BOOL(id value,NSDictionary *bindings) {
        (void)value;(void)bindings;
        __block BOOL ready;
        [self onMain:^{ ready=[[self.controller valueForKey:@"serverStarted"] boolValue] && [self.controller valueForKey:@"socket"]!=old; }];
        return ready;
    }];
    XCTestExpectation *expectation=[[XCTNSPredicateExpectation alloc] initWithPredicate:recovered object:nil];
    [self waitForExpectations:@[expectation] timeout:5];
    [self checkVersionResponse];
}
- (void)testNetworkCheckUsesAHandshakeWithoutSendingApplicationData {
    int listener=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    XCTAssertEqual(bind(listener,(void *)&address,sizeof address),0);
    XCTAssertEqual(listen(listener,1),0);
    XCTAssertEqual(fcntl(listener,F_SETFL,O_NONBLOCK),0);
    socklen_t size=sizeof address;getsockname(listener,(void *)&address,&size);
    MotionNetworkCheck *check=[MotionNetworkCheck new];
    XCTestExpectation *finished=[self expectationWithDescription:@"system path to the local listener"];
    [self onMain:^{
        [check startWithHost:@"127.0.0.1" port:ntohs(address.sin_port) changed:^(NSString *message,BOOL needsSettings) {
            XCTAssertFalse(needsSettings);XCTAssertGreaterThan(message.length,0u);
            [finished fulfill];
        }];
    }];
    [self waitForExpectations:@[finished] timeout:3];
    int peer=accept(listener,NULL,NULL);
    XCTAssertGreaterThanOrEqual(peer,0);
    if(peer>=0) {
        char buffer[1];ssize_t n=recv(peer,buffer,sizeof buffer,MSG_DONTWAIT);
        XCTAssertLessThanOrEqual(n,0);close(peer);
    }
    close(listener);[self onMain:^{ [check cancel]; }];
}
- (void)testStoppingNetworkCheckSuppressesLateCallbacks {
    MotionNetworkCheck *check=[MotionNetworkCheck new];
    XCTestExpectation *late=[self expectationWithDescription:@"no callback after Stop"];
    late.inverted=YES;
    [self onMain:^{
        [check startWithHost:@"127.0.0.1" port:9 changed:^(NSString *message,BOOL needsSettings) {
            (void)message;(void)needsSettings;[late fulfill];
        }];
        [check cancel];
    }];
    [self waitForExpectations:@[late] timeout:0.2];
}
@end
