// TIDAL's OpenAPI client (TidalAPI.URLSessionRequestBuilder) puts auth headers on the URLRequest
// and loads with -[NSURLSession dataTaskWithRequest:completionHandler:], so that's the hook.
#import "RL.h"
#import <objc/runtime.h>

static NSURLSessionDataTask *(*orig_dataTask)(NSURLSession *, SEL, NSURLRequest *, id);

static id RLAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static NSString *RLLyricsTrackId(NSURL *url) {
	NSArray<NSString *> *p = url.pathComponents;
	if (![url.host hasSuffix:@"openapi.tidal.com"] || p.count < 6) return nil;
	NSUInteger n = p.count;
	return [p[n - 1] isEqualToString:@"lyrics"] && [p[n - 2] isEqualToString:@"relationships"] && [p[n - 4] isEqualToString:@"tracks"] ? p[n - 3] : nil;
}

static NSString *RLTrackWithLyricsId(NSURL *url) {
	NSArray<NSString *> *p = url.pathComponents;
	if (![url.host hasSuffix:@"openapi.tidal.com"] || p.count < 3 || ![p[p.count - 2] isEqualToString:@"tracks"]) return nil;
	for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
		if ([q.name hasPrefix:@"include"] && [q.value containsString:@"lyrics"]) return p.lastObject;
	return nil;
}

static void RLNoteLyricsURL(NSURL *url, NSString *via) {
	static NSMutableSet *seen;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
	NSString *key = [NSString stringWithFormat:@"%@ %@", via, url.path];
	@synchronized(seen) {
		if ([seen containsObject:key] || seen.count > 200) return;
		[seen addObject:key];
	}
	RLLog(@"lyrics req (%@): %@?%@", via, url.path, url.query ?: @"");
}

static BOOL RLTidalHasLyrics(NSData *data, NSURLResponse *resp) {
	NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
	if (status == 404) return NO;
	if (status != 200) return YES;
	NSDictionary *json = data ? RLAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class) : nil;
	for (NSDictionary *inc in RLAs(json[@"included"], NSArray.class)) {
		NSDictionary *a = RLAs(RLAs(inc, NSDictionary.class)[@"attributes"], NSDictionary.class);
		if ([inc[@"type"] isEqual:@"lyrics"] && [a[@"technicalStatus"] isEqual:@"OK"] && ([RLAs(a[@"lrcText"], NSString.class) length] || [RLAs(a[@"text"], NSString.class) length])) return YES;
	}
	return NO;
}

static void RLTrackInfo(NSURLSession *session, NSURLRequest *lyricsReq, NSString *trackId, void (^done)(NSString *title, NSString *artist, NSString *isrc)) {
	NSURLComponents *c = [NSURLComponents componentsWithURL:lyricsReq.URL resolvingAgainstBaseURL:NO];
	NSString *country;
	for (NSURLQueryItem *q in c.queryItems)
		if ([q.name isEqualToString:@"countryCode"]) country = q.value;
	c.path = [NSString stringWithFormat:@"/v2/tracks/%@", trackId];
	c.queryItems = country ? @[ [NSURLQueryItem queryItemWithName:@"countryCode" value:country], [NSURLQueryItem queryItemWithName:@"include" value:@"artists"] ]
	                       : @[ [NSURLQueryItem queryItemWithName:@"include" value:@"artists"] ];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
	req.allHTTPHeaderFields = lyricsReq.allHTTPHeaderFields;
	[orig_dataTask(session, @selector(dataTaskWithRequest:completionHandler:), req, ^(NSData *data, NSURLResponse *resp, NSError *err) {
		NSDictionary *json = data ? RLAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class) : nil;
		NSDictionary *track = RLAs(json[@"data"], NSDictionary.class), *attrs = RLAs(track[@"attributes"], NSDictionary.class);
		NSString *title = RLAs(attrs[@"title"], NSString.class), *version = RLAs(attrs[@"version"], NSString.class);
		if (title && version.length) title = [NSString stringWithFormat:@"%@ (%@)", title, version];
		NSArray *artistRefs = RLAs(RLAs(RLAs(track[@"relationships"], NSDictionary.class)[@"artists"], NSDictionary.class)[@"data"], NSArray.class);
		NSString *firstId = RLAs(RLAs(artistRefs.firstObject, NSDictionary.class)[@"id"], NSString.class);
		NSString *artist;
		for (NSDictionary *inc in RLAs(json[@"included"], NSArray.class))
			if ([RLAs(inc, NSDictionary.class)[@"type"] isEqual:@"artists"] && (!artist || [inc[@"id"] isEqual:firstId]))
				artist = RLAs(RLAs(inc[@"attributes"], NSDictionary.class)[@"name"], NSString.class) ?: artist;
		done(title, artist, RLAs(attrs[@"isrc"], NSString.class));
	}) resume];
}

static NSDictionary *RLLyricsObject(NSArray<RLLine *> *lines, NSString *trackId) {
	NSMutableArray *lrc = [NSMutableArray array], *plain = [NSMutableArray array];
	for (RLLine *l in lines) {
		NSString *t = [[[l.main valueForKey:@"text"] componentsJoinedByString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if (!t.length) continue;
		[lrc addObject:[NSString stringWithFormat:@"[%02d:%05.2f] %@", (int)(l.start / 60), fmod(l.start, 60), t]];
		[plain addObject:t];
	}
	NSString *lid = [@"rl-" stringByAppendingString:trackId];
	return @{ @"id": lid, @"type": @"lyrics", @"attributes": @{
		@"text": [plain componentsJoinedByString:@"\n"],
		@"lrcText": [lrc componentsJoinedByString:@"\n"],
		@"direction": @"LEFT_TO_RIGHT",
		@"technicalStatus": @"OK",
		@"provider": @{ @"source": @"THIRD_PARTY", @"name": @"Radiant Lyrics", @"commonTrackId": trackId, @"lyricsId": lid },
	} };
}

static NSData *RLRelationshipDocument(NSDictionary *lyrics, NSString *path) {
	NSDictionary *doc = @{ @"data": @[ @{ @"id": lyrics[@"id"], @"type": @"lyrics" } ], @"included": @[ lyrics ], @"links": @{ @"self": path } };
	return [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
}

static NSData *RLTrackDocument(NSData *original, NSDictionary *lyrics, NSString *trackId) {
	NSMutableDictionary *doc = RLAs([NSJSONSerialization JSONObjectWithData:original options:NSJSONReadingMutableContainers error:nil], NSMutableDictionary.class);
	NSMutableDictionary *track = RLAs(doc[@"data"], NSMutableDictionary.class);
	if (!track) return nil;
	NSMutableDictionary *rels = RLAs(track[@"relationships"], NSMutableDictionary.class) ?: [NSMutableDictionary dictionary];
	rels[@"lyrics"] = @{ @"data": @[ @{ @"id": lyrics[@"id"], @"type": @"lyrics" } ], @"links": @{ @"self": [NSString stringWithFormat:@"/tracks/%@/relationships/lyrics", trackId] } };
	track[@"relationships"] = rels;
	doc[@"included"] = [RLAs(doc[@"included"], NSArray.class) ?: @[] arrayByAddingObject:lyrics];
	return [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
}

static NSURLSessionDataTask *hook_dataTask(NSURLSession *self, SEL _cmd, NSURLRequest *req, void (^done)(NSData *, NSURLResponse *, NSError *)) {
	if (done && [req.URL.absoluteString containsString:@"lyrics"]) RLNoteLyricsURL(req.URL, @"task");
	NSString *relId = done ? RLLyricsTrackId(req.URL) : nil;
	NSString *docId = done && !relId ? RLTrackWithLyricsId(req.URL) : nil;
	NSString *trackId = relId ?: docId;
	if (!trackId || !RLBool(@"enabled", YES)) return orig_dataTask(self, _cmd, req, done);
	return orig_dataTask(self, _cmd, req, ^(NSData *data, NSURLResponse *resp, NSError *err) {
		if (err || RLTidalHasLyrics(data, resp)) {
			RLLog(@"TIDAL lyrics for %@: %@", trackId, err ? err.localizedDescription : @"present");
			done(data, resp, err);
			return;
		}
		RLTrackInfo(self, req, trackId, ^(NSString *title, NSString *artist, NSString *isrc) {
			if (!title.length || !artist.length) { RLLog(@"no lyrics for %@, track info failed", trackId); done(data, resp, err); return; }
			RLFetch(title, artist, isrc, NO, ^(NSArray<RLLine *> *lines) {
				NSData *fake = lines.count ? (relId ? RLRelationshipDocument(RLLyricsObject(lines, trackId), req.URL.path) : RLTrackDocument(data, RLLyricsObject(lines, trackId), trackId)) : nil;
				RLLog(@"no TIDAL lyrics for %@ (%@ — %@): %@", trackId, title, artist, fake ? @"serving Radiant's" : @"Radiant has none either");
				if (!fake) { done(data, resp, err); return; }
				done(fake, [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"application/vnd.api+json" }], nil);
			});
		});
	});
}

@interface RLProbe : NSURLProtocol
@end
@implementation RLProbe
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
	if ([request.URL.absoluteString containsString:@"lyrics"]) RLNoteLyricsURL(request.URL, @"load");
	return NO;
}
@end

static NSArray *(*orig_protocolClasses)(NSURLSessionConfiguration *, SEL);
static NSArray *hook_protocolClasses(NSURLSessionConfiguration *self, SEL _cmd) {
	NSArray *a = orig_protocolClasses(self, _cmd) ?: @[];
	return [a containsObject:RLProbe.class] ? a : [@[ RLProbe.class ] arrayByAddingObjectsFromArray:a];
}

__attribute__((constructor)) static void RLLyricsInjectInit(void) {
	Class c = NSClassFromString(@"__NSURLSessionLocal") ?: NSURLSession.class;
	SEL sel = @selector(dataTaskWithRequest:completionHandler:);
	Method m = class_getInstanceMethod(c, sel);
	if (!m) return;
	if (class_addMethod(c, sel, (IMP)hook_dataTask, method_getTypeEncoding(m))) orig_dataTask = (void *)method_getImplementation(m);
	else orig_dataTask = (void *)method_setImplementation(m, (IMP)hook_dataTask);
	RLLog(@"lyrics hook on %s", class_getName(c));

	Class cfg = object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration);
	Method pm = class_getInstanceMethod(cfg, @selector(protocolClasses));
	if (!pm) return;
	if (class_addMethod(cfg, @selector(protocolClasses), (IMP)hook_protocolClasses, method_getTypeEncoding(pm))) orig_protocolClasses = (void *)method_getImplementation(pm);
	else orig_protocolClasses = (void *)method_setImplementation(pm, (IMP)hook_protocolClasses);
}
