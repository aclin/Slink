//
//  xboxproxy.m
//  Slink
//
//  Created by Tim Wu on 7/11/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "XboxProxy.h"

@implementation XboxProxySendRequest
@synthesize packet, host, port;
- (id) initWithPacket:(ProxyPacket *) _packet host:(NSString *)_host port:(UInt16)_port
{
	if (self = [super init]) {
		self.packet = _packet;
		self.host = _host;
		self.port = _port;
	}
	return self;
}

+ (id) sendRequestWithPacket:(ProxyPacket *)_packet host:(NSString *)_host port:(UInt16)_port
{
	return [[self alloc] initWithPacket:_packet host:_host port:_port];
}
@end

@implementation XboxProxy
//////////////////////////////////////////////////////////////
#pragma mark initializers
//////////////////////////////////////////////////////////////
- (id) init
{
	if (self = [super init]) {
		localProxyInfo = [ProxyInfo proxyInfoWithHost:@"0.0.0.0" port:0];
		self.running = NO;
		serverSocket = nil;
		sniffer = nil;
		routingTable = [NSMutableDictionary dictionaryWithCapacity:5];
		allKnownProxies = [MutableProxyList arrayWithCapacity:5];
		self.filter = @"(host 0.0.0.1)";
		self.dev = @"";
		sendTag = 0;
	}
	return self;
}

- (id) initWithPort:(UInt16) _port listenDevice:(NSString *) _dev
{
	if (self = [self init]) {
		self.port = [NSNumber numberWithInt:_port];
		self.dev = _dev;
	}
	return self;
}

# pragma mark Status KVO methods.
- (NSString *) status
{
	if (!self.running) {
		return @"Slink is stopped.";
	} else {
		return [NSString stringWithFormat:@"Slink is running @ %@", localProxyInfo];
	}
}

+ (NSSet *) keyPathsForValuesAffectingStatus
{
	return [NSSet setWithObjects:@"running",@"ip", @"port", nil];
}

#pragma mark Lifecycle methods.
- (BOOL) startServerSocket
{
	// Kill the previous server if it's there.
	if (serverSocket) {
		NSLog(@"XboxProxy socket server was running. Shutting it down.");
		[serverSocket close];
	}
	// The thread the server socket is running on will be xboxproxy's main thread.
	proxyThread = [NSThread currentThread];
	NSError * bindError = nil;
	NSLog(@"Starting socket server on port %d.", localProxyInfo.port);
	serverSocket = [[AsyncUdpSocket alloc] initWithDelegate:self];
	if([serverSocket bindToPort:localProxyInfo.port error:&bindError] == NO) {
		NSLog(@"Error binding to port %d. %@", localProxyInfo.port, bindError);
		return NO;
	}
	[serverSocket receiveWithTimeout:RECV_TIMEOUT tag:0];
	return YES;
}

- (BOOL) startSniffer
{
	if (sniffer) {
		NSLog(@"Sniffer already opened. Closing it...");
		[sniffer close];
	}
	NSLog(@"Starting sniffer on interface %@.", self.dev);
	sniffer = [[PcapListener alloc] initWithInterface:self.dev withDelegate:self AndFilter:filter];
	return sniffer != nil;
}

- (BOOL) start
{
	if (self.running) {
		NSLog(@"XboxProxy is already running.");
		return YES;
	}
	if ([self startSniffer] == NO) {
		NSLog(@"Error starting packet sniffer.");
		return NO;
	}
	if ([self startServerSocket] == NO) {
		NSLog(@"Error starting server socket.");
		return NO;
	}
	self.running = YES;
	[[NSNotificationCenter defaultCenter] postNotificationName:XPStarted object:self];
	return YES;
}

- (void) close
{
	[serverSocket close];
	serverSocket = nil;
	self.filter = @"(host 0.0.0.1)";
	[sniffer close];
	sniffer = nil;
	routingTable = [NSMutableDictionary dictionaryWithCapacity:5];
	for(int i = 0; i < [self countOfAllKnownProxies]; i++) {
		[self removeObjectFromAllKnownProxiesAtIndex:0];
	}
	self.running = NO;
	[[NSNotificationCenter defaultCenter] postNotificationName:XPStopped object:self];
}
	

- (void) connectTo:(NSString *)host port:(UInt16)port
{
	NSLog(@"Connecting to %@:%d", host, port);
	// List proxies from remote
	[self send:[ProxyPacket listProxyReqPacket] toHost:host port:port];
	// Greet remote with "Introduce" packet
	[self send:[ProxyPacket introducePacketToHost:host port:port] toHost:host port:port];
	// Send your list of proxies
	[self send:[[allKnownProxies filteredProxyListForHost:host port:port] proxyListPacket] toHost:host port:port];
}

- (void) send:(ProxyPacket *) packet toHost:(NSString *) host port:(UInt16) port
{
	[self performSelector:@selector(doSend:) 
				 onThread:proxyThread 
			   withObject:[XboxProxySendRequest sendRequestWithPacket:packet host:host port:port] 
			waitUntilDone:NO];
}

- (void) send:(id) data toProxy:(ProxyInfo *) proxy
{
	[self send:data toHost:proxy.ipAsString port:proxy.port];
}

- (void) doSend:(XboxProxySendRequest *) sendReq
{
	if ([serverSocket sendData:sendReq.packet toHost:sendReq.host port:sendReq.port withTimeout:SEND_TIMEOUT tag:sendTag++] == NO) {
		NSLog(@"Error sending packet.");
	}
}
//////////////////////////////////////////////////////////////
#pragma mark getters/setters
//////////////////////////////////////////////////////////////
@synthesize running;
@synthesize dev;
- (void) setDev:(NSString *)_dev
{
	if ([_dev isEqual:dev]) {
		return;
	}
	dev = _dev;
	if (self.running) {
		[self startSniffer];
	}
}

@synthesize filter;
- (void) setFilter:(NSString *)_filter
{
	filter = _filter;
	NSLog(@"Filter changed to %@", filter);
	if (sniffer) {
		[sniffer setFilter:filter];
	}
}

- (void) updateBroadcastArray:(ProxyInfo *) candidateProxy
{
	for(ProxyInfo * proxy in allKnownProxies) {
		if ([proxy isEqualTo:candidateProxy]) {
			// we already know about this proxy
			return;
		}
	}
	[self insertObject:candidateProxy inAllKnownProxiesAtIndex:0];
}

- (NSUInteger) countOfAllKnownProxies
{
	return [allKnownProxies count];
}

- (id) objectInAllKnownProxiesAtIndex:(NSUInteger) index
{
	return [allKnownProxies objectAtIndex:index];
}

- (void) insertObject:(ProxyInfo *) proxyInfo inAllKnownProxiesAtIndex:(NSUInteger) index
{
	[allKnownProxies insertObject:proxyInfo atIndex:index];
}

- (void) removeObjectFromAllKnownProxiesAtIndex:(NSUInteger) index
{
	[allKnownProxies removeObjectAtIndex:index];
}

- (void) setIp:(NSString *) ip
{
	localProxyInfo.ipAsString = ip;
}

- (NSString *) ip
{
	return localProxyInfo.ipAsString;
}

- (void) setPort:(NSNumber *) port
{
	if ([port intValue] != localProxyInfo.port) {
		localProxyInfo.port = [port intValue];
		if (self.running) {
			[self startServerSocket];
		}
	}
}

- (NSNumber *) port
{
	return [NSNumber numberWithInt:localProxyInfo.port];
}
//////////////////////////////////////////////////////////////
#pragma mark packet handling methods
//////////////////////////////////////////////////////////////
- (void) handleSniffedPacket:(ProxyPacket *) packet
{
	MacAddress * dstMacAddress = packet.dstMacAddress;
	if ([dstMacAddress isEqual:BROADCAST_MAC]) {
		for(id proxyInfo in allKnownProxies) {
			[self send:packet toProxy:proxyInfo];
		}
		return;
	}
	ProxyInfo * destinationServer = [routingTable objectForKey:dstMacAddress];
	if (destinationServer == nil) {
		NSLog(@"Got an unknown mac: %@", dstMacAddress);
	} else {
		[self send:packet toProxy:destinationServer];
	}
}

- (void) handleProxyListReqFromHost:(NSString *) host port:(UInt16) port
{
	NSLog(@"Got a proxy list request.");
	[self send:[[allKnownProxies filteredProxyListForHost:host port:port] proxyListPacket] toHost:host port:port];
}

- (void) handleProxyListPacket:(ProxyPacket *) packet
{
	ProxyList * proxyList = packet.proxyList;
	NSLog(@"Got a proxy list packet.");
	for(ProxyInfo * proxyInfo in proxyList) {
		NSLog(@"Sending introduction to: %@", proxyInfo);
		[self send:[ProxyPacket introducePacketToHost:proxyInfo.ipAsString port:proxyInfo.port] 
			toHost:proxyInfo.ipAsString port:proxyInfo.port];
	}
}

- (void) handleInject:(ProxyPacket *)packet fromHost:(NSString *) host port:(UInt16) port
{	
	// Check if this mac address is in the map, if not update the map with the new mac, and where it came from
	MacAddress * srcMacAddress = packet.srcMacAddress;
	if ([routingTable objectForKey:srcMacAddress] == nil) {
		NSLog(@"Updating mac -> destination map with entry [%@ -> %@:%d]", srcMacAddress, host, port);
		[routingTable setObject:[ProxyInfo proxyInfoWithHost:host port:port] forKey:srcMacAddress];
		// Since this is a remote mac address, add it to the pcap filtering so we don't get inject feedback.
		self.filter = [NSString stringWithFormat:@"%@ && !(ether src %@)", self.filter, srcMacAddress];
	}
	[sniffer inject:packet];
}

- (void) handleIntroduce:(ProxyPacket *) packet fromHost:(NSString *) host port:(UInt16) port
{
	ProxyInfo * proxyInfo = [ProxyInfo proxyInfoWithHost:host port:port];
	NSLog(@"Got an introduction from %@", proxyInfo);
	[self updateBroadcastArray:proxyInfo];
	// Also acknowledge the introduction
	[self send:[ProxyPacket introduceAckPacket:proxyInfo] toHost:host port:port];
	if (localProxyInfo.ip == 0) {
		ProxyInfo * newProxyInfo = [packet receiverProxyInfo];
		NSLog(@"Updating external ip with %@", newProxyInfo.ipAsString);
		self.ip = newProxyInfo.ipAsString;
	}
}

- (void) handleIntroduceAck:(ProxyPacket *) packet fromHost:(NSString *) host port:(UInt16) port
{
	NSLog(@"Got introduce ack from %@:%d", host, port);
	[self updateBroadcastArray:[ProxyInfo proxyInfoWithHost:host port:port]];
	if (localProxyInfo.ip == 0) {
		ProxyInfo * newProxyInfo = [packet receiverProxyInfo];
		NSLog(@"Updating external ip with %@", newProxyInfo.ipAsString);
		self.ip = newProxyInfo.ipAsString;
	}
}

//////////////////////////////////////////////////////////////
#pragma mark Udp Socket Receive Delegate
//////////////////////////////////////////////////////////////
- (BOOL)onUdpSocket:(AsyncUdpSocket *)sock didReceiveData:(ProxyPacket *)packet withTag:(long)tag fromHost:(NSString *)host port:(UInt16)port
{
	switch (packet.packetType) {
		case INJECT:
			[self handleInject:packet fromHost:host port:port];
			break;
		case INTRODUCE:
			[self handleIntroduce:packet fromHost:host port:port];
			break;
		case INTRODUCE_ACK:
			[self handleIntroduceAck:packet fromHost:host port:port];
			break;
		case LIST_PROXY_REQ:
			[self handleProxyListReqFromHost:host port:port];
			break;
		case PROXY_LIST:
			[self handleProxyListPacket:packet];
			break;
		default:
			NSLog(@"Got an unknown packet!");
			break;
	}
	[sock receiveWithTimeout:RECV_TIMEOUT tag:tag+1];
	return YES;
}

- (void)onUdpSocket:(AsyncUdpSocket *)sock didNotReceiveDataWithTag:(long)tag dueToError:(NSError *)error
{
	if ([error code] != AsyncUdpSocketReceiveTimeoutError) {
		NSLog(@"Failed to receive packet due to :%@", error);
	}
	[sock receiveWithTimeout:RECV_TIMEOUT tag:tag];
}

- (void)onUdpSocket:(AsyncUdpSocket *)sock didSendDataWithTag:(long)tag
{
}

- (void)onUdpSocket:(AsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error
{
	NSLog(@"Error sending: %@", error);
}
@end
