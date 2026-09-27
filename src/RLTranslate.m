#import "RL.h"

// Musixmatch answers an anonymous token, which is kept: asking token.get too often gets a captcha.

static NSString *const kAPI = @"https://apic-appmobile.musixmatch.com/ws/1.1/";

static id RLAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static NSDictionary *RLMxm(NSString *method, NSString *query, NSInteger *status) {
	NSString *url = [NSString stringWithFormat:@"%@%@?format=json&app_id=mac-ios-v2.0&%@", kAPI, method, query];
	NSData *d;
	RLGet(url, @{ @"Accept": @"application/json", @"x-mxm-app-version": @"10.1.1", @"X-User-Agent": @"Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0" }, 10, &d);
	NSDictionary *msg = RLAs(RLAs(d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil, NSDictionary.class)[@"message"], NSDictionary.class);
	*status = [RLAs(RLAs(msg[@"header"], NSDictionary.class)[@"status_code"], NSNumber.class) integerValue];
	return RLAs(msg[@"body"], NSDictionary.class);
}

static NSString *RLMxmToken(BOOL fresh) {
	NSString *token = fresh ? nil : RLAs([RLDefaults objectForKey:@"rl.mxmToken"], NSString.class);
	if (token.length) return token;
	NSInteger st;
	token = RLAs(RLMxm(@"token.get", @"", &st)[@"user_token"], NSString.class);
	RLLog(@"musixmatch: token %@ (%ld)", token.length ? @"received" : @"refused", (long)st);
	if (!token.length) return nil;
	RLSet(@"mxmToken", token);
	return token;
}

static NSArray<NSArray<NSString *> *> *RLMusixmatchFor(NSString *title, NSString *artist, NSString *lang) {
	for (int attempt = 0; attempt < 2; attempt++) {
		NSString *token = RLMxmToken(attempt > 0);
		if (!token) return nil;
		NSInteger st;
		NSDictionary *track = RLAs(RLMxm(@"matcher.track.get", [NSString stringWithFormat:@"usertoken=%@&q_track=%@&q_artist=%@", RLEnc(token), RLEnc(title), RLEnc(artist)], &st)[@"track"], NSDictionary.class);
		if (st == 401) continue;
		NSNumber *tid = RLAs(track[@"track_id"], NSNumber.class);
		if (!tid) { RLLog(@"musixmatch: no match for %@ — %@ (%ld)", title, artist, (long)st); return @[]; }
		NSDictionary *body = RLMxm(@"crowd.track.translations.get", [NSString stringWithFormat:@"usertoken=%@&track_id=%@&selected_language=%@&translation_fields_set=minimal&comment_format=text", RLEnc(token), tid, RLEnc(lang)], &st);
		if (st == 401) continue;
		NSMutableArray *map = [NSMutableArray array];
		for (NSDictionary *item in RLAs(body[@"translations_list"], NSArray.class)) {
			NSDictionary *t = RLAs(RLAs(item, NSDictionary.class)[@"translation"], NSDictionary.class);
			NSString *from = RLAs(t[@"snippet"], NSString.class) ?: RLAs(t[@"matched_line"], NSString.class);
			NSString *to = [RLAs(t[@"description"], NSString.class) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			if (from.length && to.length && ![RLLineKey(to) isEqualToString:RLLineKey(from)]) [map addObject:@[ RLLineKey(from), to ]];
		}
		RLLog(@"musixmatch: %lu %@ lines for %@ — %@", (unsigned long)map.count, lang, title, artist);
		return map;
	}
	return nil;
}

// often has half. VIBE closes on 2026-12-31; after that this fails and Musixmatch is asked alone -- delete it then.
static NSArray<NSArray<NSString *> *> *RLVibeFor(NSString *title, NSString *artist) {
	NSDictionary *h = @{ @"Accept": @"application/json", @"Referer": @"https://vibe.naver.com/" };
	NSString *base = @"https://apis.naver.com/vibeWeb/musicapiweb/";
	NSData *d;
	if (RLGet([NSString stringWithFormat:@"%@v4/searchall?query=%@", base, RLEnc([NSString stringWithFormat:@"%@ %@", title, artist])], h, 8, &d) != 200) return nil;
	id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
	NSArray *tracks = RLAs(RLAs(RLAs(RLAs(RLAs(json, NSDictionary.class)[@"response"], NSDictionary.class)[@"result"], NSDictionary.class)[@"trackResult"], NSDictionary.class)[@"tracks"], NSArray.class);
	NSDictionary *track = RLAs(tracks.firstObject, NSDictionary.class);
	NSString *found = RLLineKey(RLAs(track[@"trackTitle"], NSString.class) ?: @""), *want = RLLineKey(title);
	NSNumber *tid = RLAs(track[@"trackId"], NSNumber.class);
	// the artist is not compared: VIBE may name them in another script (米津玄師 for Kenshi Yonezu)
	if (!tid || !found.length || !want.length || !([found hasPrefix:want] || [want hasPrefix:found])) { RLLog(@"vibe: no match for %@ — %@", title, artist); return @[]; }
	if (RLGet([NSString stringWithFormat:@"%@vibe/v4/lyric/%@", base, tid], h, 8, &d) != 200) return nil;
	json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
	NSDictionary *sync = RLAs(RLAs(RLAs(RLAs(RLAs(json, NSDictionary.class)[@"response"], NSDictionary.class)[@"result"], NSDictionary.class)[@"lyric"], NSDictionary.class)[@"syncLyric"], NSDictionary.class);
	NSArray *orig, *ko;
	for (NSDictionary *c in RLAs(sync[@"contents"], NSArray.class)) {
		NSString *lang = RLAs(RLAs(c, NSDictionary.class)[@"languageType"], NSString.class);
		NSArray *text = RLAs(RLAs(c, NSDictionary.class)[@"text"], NSArray.class);
		if ([lang isEqualToString:@"ko"]) ko = text;
		else if (!orig) orig = text;
	}
	NSMutableArray *map = [NSMutableArray array];
	for (NSUInteger i = 0; i < MIN(orig.count, ko.count); i++) {
		NSString *from = RLAs(orig[i], NSString.class), *to = [RLAs(ko[i], NSString.class) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if (RLLineKey(from ?: @"").length && to.length && ![RLLineKey(to) isEqualToString:RLLineKey(from)]) [map addObject:@[ RLLineKey(from), to ]];
	}
	RLLog(@"vibe: %lu ko lines for %@ — %@ (%@)", (unsigned long)map.count, title, artist, tid);
	return map;
}

static NSUInteger RLLev(NSString *a, NSString *b) {
	NSUInteger n = b.length, prev[n + 1], cur[n + 1];
	for (NSUInteger j = 0; j <= n; j++) prev[j] = j;
	for (NSUInteger i = 1; i <= a.length; i++) {
		cur[0] = i;
		unichar x = [a characterAtIndex:i - 1];
		for (NSUInteger j = 1; j <= n; j++)
			cur[j] = MIN(MIN(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (x != [b characterAtIndex:j - 1]));
		memcpy(prev, cur, sizeof(cur));
	}
	return prev[n];
}

// ponytail: O(lines x snippets x len^2), fine for a song; index by prefix if it ever shows in a profile
static NSString *RLMatch(NSString *key, NSArray<NSArray<NSString *> *> *src) {
	double best = 0.8;
	NSString *out;
	for (NSUInteger i = 0; i < src.count; i++)
		for (NSUInteger n = 1; n <= 2 && i + n <= src.count; n++) {
			// not valueForKey: on the pairs -- KVC on an NSArray maps into each pair's strings and throws
			NSString *k = src[i][0], *text = src[i][1];
			if (n == 2) k = [k stringByAppendingString:src[i + 1][0]], text = [NSString stringWithFormat:@"%@ %@", text, src[i + 1][1]];
			double r = 1 - (double)RLLev(key, k) / MAX(1, MAX(key.length, k.length));
			if (r > best) best = r, out = text;
		}
	return out;
}

void RLTranslate(NSArray<RLLine *> *lines, NSString *title, NSString *artist, NSString *lang, void (^done)(BOOL found)) {
	static NSCache *cache;
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = [NSCache new];
		queue = dispatch_queue_create("rl.translate", DISPATCH_QUEUE_SERIAL);
	});
	if (!lines.count || !title.length || !artist.length) { done(NO); return; }
	dispatch_async(queue, ^{
		// Each source fills only the lines the ones before it left empty: VIBE may join two lines Apple splits,
		// and Musixmatch has those halves.
		NSMutableArray *found = [NSMutableArray array];
		for (NSUInteger i = 0; i < lines.count; i++) [found addObject:NSNull.null];
		BOOL any = NO;
		for (NSString *source in [lang isEqualToString:@"ko"] ? @[ @"vibe", @"musixmatch" ] : @[ @"musixmatch" ]) {
			if (![found containsObject:NSNull.null]) break;
			NSString *key = [NSString stringWithFormat:@"%@\n%@\n%@\n%@", source, title, artist, lang];
			NSArray *map = [cache objectForKey:key] ?: ([source isEqualToString:@"vibe"] ? RLVibeFor(title, artist) : RLMusixmatchFor(title, artist, lang));
			if (!map) continue;
			[cache setObject:map forKey:key];
			for (NSUInteger i = 0; i < lines.count && map.count; i++) {
				if (found[i] != NSNull.null || !lines[i].key.length) continue;
				NSString *text = RLMatch(lines[i].key, map);
				if (text) found[i] = text, any = YES;
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!any) { done(NO); return; }
			[lines enumerateObjectsUsingBlock:^(RLLine *l, NSUInteger i, BOOL *stop) {
				if (!l.mx) l.mx = [NSMutableDictionary dictionary];
				l.mx[lang] = found[i] == NSNull.null ? @[] : RLWords(found[i], l.start);
			}];
			done(YES);
		});
	});
}
