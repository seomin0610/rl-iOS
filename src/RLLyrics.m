#import "RL.h"
#import <os/log.h>

@implementation RLSyl
@end
@implementation RLLine
@end

static id RLAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static NSMutableArray<NSString *> *gLog;

void RLLogLine(NSString *line) {
	os_log(OS_LOG_DEFAULT, "[RadiantTidal] %{public}@", line);
	static NSDateFormatter *f;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		gLog = [NSMutableArray array];
		f = [NSDateFormatter new];
		f.dateFormat = @"HH:mm:ss";
	});
	@synchronized(gLog) {
		[gLog addObject:[NSString stringWithFormat:@"%@ %@", [f stringFromDate:NSDate.date], line]];
		if (gLog.count > 60) [gLog removeObjectAtIndex:0];
	}
}

NSArray<NSString *> *RLLogLines(void) {
	if (!gLog) return @[];
	@synchronized(gLog) { return [gLog copy]; }
}

static NSString *RLCollapse(NSString *s) {
	static NSRegularExpression *re;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil]; });
	return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
}

NSArray<RLSyl *> *RLWords(NSString *text, double t) {
	NSMutableArray *out = [NSMutableArray array];
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\S+\\s*" options:0 error:nil];
	for (NSTextCheckingResult *m in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
		RLSyl *s = [RLSyl new];
		s.text = [text substringWithRange:m.range];
		s.start = s.end = t;
		[out addObject:s];
	}
	return out;
}

static NSArray<NSNumber *> *RLSides(NSArray *data, NSDictionary *agents) {
	NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionary];
	NSInteger persons = 0;
	for (NSDictionary *l in data) {
		NSString *sid = RLAs(RLAs(RLAs(l, NSDictionary.class)[@"element"], NSDictionary.class)[@"singer"], NSString.class);
		if (!sid || map[sid]) continue;
		NSString *type = RLAs(RLAs(agents[sid], NSDictionary.class)[@"type"], NSString.class);
		if (!type) type = [sid isEqualToString:@"v1000"] ? @"group" : [sid isEqualToString:@"v2000"] ? @"other" : @"person";
		map[sid] = @(!([type isEqualToString:@"group"] || [type isEqualToString:@"other"]) && ++persons == 2);
	}
	NSMutableArray *sides = [NSMutableArray array];
	NSInteger right = 0, total = 0;
	for (NSDictionary *l in data) {
		NSString *sid = RLAs(RLAs(RLAs(l, NSDictionary.class)[@"element"], NSDictionary.class)[@"singer"], NSString.class);
		BOOL r = sid && [map[sid] boolValue];
		if (sid) total++;
		if (r) right++;
		[sides addObject:@(r)];
	}
	if (total && llround(right * 100.0 / total) >= 85)
		for (NSUInteger i = 0; i < sides.count; i++) sides[i] = @(![sides[i] boolValue]);
	return sides;
}

NSString *RLLineKey(NSString *s) {
	return [[s.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}

NSArray<RLLine *> *RLParse(NSDictionary *json, BOOL romanize) {
	NSArray *data = RLAs(json[@"data"], NSArray.class);
	if (!data) return nil;
	NSArray *sides = RLSides(data, RLAs(RLAs(json[@"metadata"], NSDictionary.class)[@"agents"], NSDictionary.class));
	NSMutableArray *lines = [NSMutableArray array];
	[data enumerateObjectsUsingBlock:^(NSDictionary *l, NSUInteger i, BOOL *stop) {
		if (!RLAs(l, NSDictionary.class)) return;
		RLLine *line = [RLLine new];
		line.start = [RLAs(l[@"startTime"], NSNumber.class) doubleValue];
		NSNumber *end = RLAs(l[@"endTime"], NSNumber.class);
		line.end = end ? end.doubleValue : line.start + [RLAs(l[@"duration"], NSNumber.class) doubleValue];
		line.right = [sides[i] boolValue];

		NSMutableArray *main = [NSMutableArray array], *bg = [NSMutableArray array];
		for (NSDictionary *s in RLAs(l[@"syllabus"], NSArray.class)) {
			if (!RLAs(s, NSDictionary.class)) continue;
			NSString *text = RLAs(s[@"text"], NSString.class);
			NSString *roman = RLAs(s[@"romanized"], NSString.class);
			if (romanize && roman.length) text = RLCollapse(roman);
			if (!text.length) continue;
			RLSyl *syl = [RLSyl new];
			syl.text = text;
			syl.start = [RLAs(s[@"time"], NSNumber.class) doubleValue] / 1000.0;
			syl.end = syl.start + [RLAs(s[@"duration"], NSNumber.class) doubleValue] / 1000.0;
			[[RLAs(s[@"isBackground"], NSNumber.class) boolValue] ? bg : main addObject:syl];
		}
		if (!main.count && !bg.count) {
			NSString *text = RLAs(l[@"text"], NSString.class);
			NSString *roman = RLAs(l[@"romanized"], NSString.class);
			if (romanize && roman.length) text = RLCollapse(roman);
			if (text) [main addObjectsFromArray:RLWords(text, line.start)];
		}
		if (!main.count) { [main addObjectsFromArray:bg]; [bg removeAllObjects]; }
		for (RLSyl *b in bg.copy) {
			b.text = [[b.text stringByReplacingOccurrencesOfString:@"(" withString:@""] stringByReplacingOccurrencesOfString:@")" withString:@""];
			if (![b.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) [bg removeObject:b];
		}
		for (RLSyl *x in [main arrayByAddingObjectsFromArray:bg]) line.end = MAX(line.end, x.end);
		if (![[[main valueForKey:@"text"] componentsJoinedByString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return;
		line.main = main;
		line.bg = bg;
		line.key = RLLineKey(RLAs(l[@"text"], NSString.class) ?: [[main valueForKey:@"text"] componentsJoinedByString:@""]);
		id tr = l[@"translation"];
		NSString *trText = RLAs(RLAs(tr, NSDictionary.class)[@"text"], NSString.class) ?: RLAs(tr, NSString.class);
		if (trText.length && ![RLLineKey(trText) isEqualToString:line.key])
			line.tr = RLWords(RLCollapse(trText), line.start);
		[lines addObject:line];
	}];
	return lines;
}

#pragma mark - Network

NSInteger RLGet(NSString *url, NSDictionary *headers, NSTimeInterval timeout, NSData **out) {
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
	[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
	__block NSInteger status = 0;
	__block NSData *body;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		status = e ? 0 : ((NSHTTPURLResponse *)r).statusCode;
		body = d;
		dispatch_semaphore_signal(sem);
	}] resume];
	dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
	if (out) *out = body;
	return status;
}

NSString *RLEnc(NSString *s) {
	static NSCharacterSet *ok;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ ok = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"]; });
	return [s stringByAddingPercentEncodingWithAllowedCharacters:ok] ?: @"";
}

static NSString *RLReplace(NSString *s, NSString *pattern) {
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
	s = [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
	return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

// Same endpoints/token as radiant-lyrics-luna api.ts (the token is public by design)
static NSCache *gLyricsCache;

void RLClearCache(void) { [gLyricsCache removeAllObjects]; }

void RLFetch(NSString *title, NSString *artist, NSString *isrc, BOOL flush, void (^done)(NSArray<RLLine *> *lines)) {
	static dispatch_queue_t queue;
	static NSString *ip;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("rl.fetch", DISPATCH_QUEUE_SERIAL);
		gLyricsCache = [NSCache new];
	});
	BOOL romanize = RLBool(@"romanize", NO), synth = RLBool(@"synth", NO);
	NSString *key = [NSString stringWithFormat:@"%@\n%@\n%d%d", title, artist, romanize, synth];

	dispatch_async(queue, ^{
		id hit = flush ? nil : [gLyricsCache objectForKey:key];
		if (hit) {
			dispatch_async(dispatch_get_main_queue(), ^{ done(hit == NSNull.null ? nil : hit); });
			return;
		}
		if (!ip) {
			NSData *d;
			if (RLGet(@"https://api.ipify.org?format=text", nil, 4, &d) == 200)
				ip = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		}
		NSDictionary *auth = @{ @"P-Access-Token-Id": @"58hy4s86", @"P-Access-Token": @"xjehy2lfg5h5mjwotoxrcqugam", @"x-client-ip": ip ?: @"null" };

		NSString *cleanTitle = RLReplace(RLReplace(title, @"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]"), @"\\s+-\\s+.*$");
		NSString *firstArtist = RLReplace(artist, @"\\s*(,|&|\\sfeat\\.?\\s|\\sft\\.?\\s|\\swith\\s).*$");
		NSOrderedSet *cands = [NSOrderedSet orderedSetWithArray:@[ @[title, artist], @[cleanTitle, artist], @[cleanTitle, firstArtist] ]];

		NSArray *result;
		for (NSArray *c in cands) {
			if (![c[0] length] || ![c[1] length]) continue;
			NSString *qs = [NSString stringWithFormat:@"?title=%@&artist=%@%@%@%@%@&platform=rl", RLEnc(c[0]), RLEnc(c[1]),
			                isrc.length ? [@"&isrc=" stringByAppendingString:RLEnc(isrc)] : @"",
			                romanize ? @"&romanize=true" : @"", synth ? @"&synthesize=true" : @"",
			                flush && c == cands.firstObject ? @"&flush=true" : @""];
			BOOL notFound = NO;
			for (NSString *base in @[ @"https://api.atomix.one/rl-api", @"https://rl-api.kineticsand.net/lyrics" ]) {
				NSData *d;
				NSInteger st = RLGet([base stringByAppendingString:qs], [base containsString:@"atomix"] ? auth : nil, 12, &d);
				RLLog(@"%ld %@ — %@ (%@)", (long)st, c[0], c[1], base);
				if (st == 404) { notFound = YES; break; }
				if (st != 200) continue;
				NSDictionary *json = d ? RLAs([NSJSONSerialization JSONObjectWithData:d options:0 error:nil], NSDictionary.class) : nil;
				NSString *note = RLAs(json[@"_flush"], NSString.class);
				if (note.length) RLLog(@"flush: %@", note);
				result = RLParse(json, romanize);
				notFound = !result.count;
				break;
			}
			if (result.count) break;
			if (!notFound) {
				dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
				return;
			}
		}
		[gLyricsCache setObject:result.count ? result : NSNull.null forKey:key];
		dispatch_async(dispatch_get_main_queue(), ^{ done(result.count ? result : nil); });
	});
}
