// Pure ObjC runtime hooks: no CydiaSubstrate/ElleKit, works injected into a sideloaded IPA.
#import "RL.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import <pthread.h>

static void RLHook(Class c, SEL sel, IMP imp, IMP *orig) {
	Method m = class_getInstanceMethod(c, sel);
	if (!m) { RLLog(@"missing %@ %@", c, NSStringFromSelector(sel)); return; }
	if (class_addMethod(c, sel, imp, method_getTypeEncoding(m))) *orig = method_getImplementation(m);
	else *orig = method_setImplementation(m, imp);
}

#pragma mark - Remote commands

@interface RLSeekEvent : MPChangePlaybackPositionCommandEvent
@property (nonatomic, strong) MPRemoteCommand *rlCommand;
@property (nonatomic) NSTimeInterval rlPosition;
@end
@implementation RLSeekEvent
- (MPRemoteCommand *)command { return _rlCommand; }
- (NSTimeInterval)positionTime { return _rlPosition; }
@end

@interface RLTarget : NSObject
@property (nonatomic, weak) id target, token;
@property (nonatomic) SEL action;
@property (nonatomic, copy) MPRemoteCommandHandlerStatus (^handler)(MPRemoteCommandEvent *);
@end
@implementation RLTarget
@end

static char kRLTargets;

static NSMutableArray<RLTarget *> *RLTargets(MPRemoteCommand *cmd) {
	NSMutableArray *a = objc_getAssociatedObject(cmd, &kRLTargets);
	if (!a) objc_setAssociatedObject(cmd, &kRLTargets, a = [NSMutableArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return a;
}

static id (*orig_addHandler)(MPRemoteCommand *, SEL, id);
static id hook_addHandler(MPRemoteCommand *self, SEL _cmd, MPRemoteCommandHandlerStatus (^handler)(MPRemoteCommandEvent *)) {
	id token = orig_addHandler(self, _cmd, handler);
	if (handler) @synchronized(self) {
		RLTarget *t = [RLTarget new];
		t.handler = handler;
		t.token = token;
		[RLTargets(self) addObject:t];
	}
	return token;
}

static void (*orig_addTarget)(MPRemoteCommand *, SEL, id, SEL);
static void hook_addTarget(MPRemoteCommand *self, SEL _cmd, id target, SEL action) {
	orig_addTarget(self, _cmd, target, action);
	if (target && action) @synchronized(self) {
		RLTarget *t = [RLTarget new];
		t.target = target;
		t.action = action;
		[RLTargets(self) addObject:t];
	}
}

static void (*orig_removeTarget)(MPRemoteCommand *, SEL, id);
static void hook_removeTarget(MPRemoteCommand *self, SEL _cmd, id target) {
	@synchronized(self) {
		NSMutableArray<RLTarget *> *a = RLTargets(self);
		for (RLTarget *t in a.copy)
			if (!target || t.target == target || t.token == target) [a removeObject:t];
	}
	orig_removeTarget(self, _cmd, target);
}

static BOOL RLInvoke(MPRemoteCommand *cmd, MPRemoteCommandEvent *event) {
	NSArray<RLTarget *> *targets;
	@synchronized(cmd) { targets = [RLTargets(cmd) copy]; }
	for (RLTarget *t in targets) {
		if (t.handler) t.handler(event);
		else if (t.target) ((NSInteger (*)(id, SEL, id))objc_msgSend)(t.target, t.action, event);
	}
	if (!targets.count) RLLog(@"no TIDAL handler for %@", cmd);
	return targets.count > 0;
}

#pragma mark - Store

static __weak RLLyricsView *gLyricsView;
static RLBackdrop *gBackdrop;
static void RLSync(void);
static void RLSyncBackdrop(void);
static void RLDumpPlayer(UIView *hv);
static void RLCheckGradient(CAGradientLayer *g);
static void RLUntint(void);

@interface RLStore ()
@property (nonatomic, copy) NSString *title, *artist;
@property (nonatomic) NSArray<RLLine *> *lines;
@property (nonatomic) RLStatus status;
@property (nonatomic) UIImage *artwork;
@end

@implementation RLStore {
	double _elapsed, _rate, _stamp, _duration;
	NSUInteger _fetchId;
	id _artworkObj;
}

+ (instancetype)shared {
	static RLStore *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [RLStore new]; });
	return s;
}

- (BOOL)playing { return _rate > 0; }

- (double)rawNow {
	double t = _elapsed + (CACurrentMediaTime() - _stamp) * _rate;
	return _duration > 0 ? MIN(t, _duration) : t;
}

- (double)now { return [self rawNow] + RLNum(@"offsetMs", 0) / 1000.0; }

- (void)nowPlayingInfo:(NSDictionary *)info stamp:(double)stamp {
	NSNumber *el = info[MPNowPlayingInfoPropertyElapsedPlaybackTime], *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
	if (rate && !el) { _elapsed = [self rawNow]; _stamp = stamp; }
	if (el) { _elapsed = el.doubleValue; _stamp = stamp; }
	if (rate) _rate = rate.doubleValue;
	if (info[MPMediaItemPropertyPlaybackDuration]) _duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];

	NSString *title = info[MPMediaItemPropertyTitle], *artist = info[MPMediaItemPropertyArtist];
	if (title.length && artist.length && !([title isEqualToString:_title] && [artist isEqualToString:_artist])) {
		self.title = title;
		self.artist = artist;
		[self refetch];
	}
	id art = info[MPMediaItemPropertyArtwork];
	if (art && art != _artworkObj) {
		_artworkObj = art;
		self.artwork = [art isKindOfClass:MPMediaItemArtwork.class] ? [art imageWithSize:CGSizeMake(256, 256)] : nil;
		[gBackdrop setCover:self.artwork];
	}
}

- (void)refetch { [self refetch:NO]; }

- (void)refetch:(BOOL)flush {
	if (!_title) return;
	NSUInteger fid = ++_fetchId;
	self.lines = nil;
	self.status = RLStatusLoading;
	RLSync();
	RLFetch(_title, _artist, nil, flush, ^(NSArray<RLLine *> *lines) {
		if (fid != self->_fetchId) return;
		self.lines = lines;
		self.status = lines ? RLStatusOK : RLStatusMissing;
		RLLog(@"%lu lines for %@ — %@", (unsigned long)lines.count, self.title, self.artist);
		[gLyricsView reload];
		RLSync();
		[self translate];
	});
}

- (void)translate {
	NSArray<RLLine *> *lines = self.lines;
	NSString *lang = RLTrLang();
	if (!RLBool(@"tr", NO) || [lang isEqualToString:@"en"] || !lines.count || lines.firstObject.mx[lang]) return;
	NSUInteger fid = _fetchId;
	RLTranslate(lines, _title, _artist, lang, ^(BOOL found) {
		if (found && fid == self->_fetchId) [gLyricsView rebuild];
	});
}

- (void)seek:(double)t {
	t = MAX(0, t - RLNum(@"offsetMs", 0) / 1000.0);
	MPChangePlaybackPositionCommand *cmd = MPRemoteCommandCenter.sharedCommandCenter.changePlaybackPositionCommand;
	RLSeekEvent *e = class_createInstance(RLSeekEvent.class, 0);
	e.rlCommand = cmd;
	e.rlPosition = t;
	if (cmd.enabled && RLInvoke(cmd, e)) { _elapsed = t; _stamp = CACurrentMediaTime(); }
}
@end

static void (*orig_setInfo)(MPNowPlayingInfoCenter *, SEL, NSDictionary *);
static void hook_setInfo(MPNowPlayingInfoCenter *self, SEL _cmd, NSDictionary *info) {
	orig_setInfo(self, _cmd, info);
	double stamp = CACurrentMediaTime();
	NSDictionary *copy = [info copy];
	dispatch_async(dispatch_get_main_queue(), ^{ [RLStore.shared nowPlayingInfo:copy stamp:stamp]; });
}

#pragma mark - Finding TIDAL's lyrics view

static __weak UIViewController *gHost;
static __weak UIViewController *gLegacy;
static __weak id gBridge;
static NSTimer *gPoll;

static void *RLIvar(id obj, const char *name) {
	Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
	return iv ? (char *)(__bridge void *)obj + ivar_getOffset(iv) : NULL;
}

static BOOL RLOnScreen(UIViewController *vc) {
	UIView *v = vc.viewIfLoaded;
	if (!v.window || v.hidden || v.alpha < 0.01 || vc.isBeingDismissed) return NO;
	CGRect r = [v convertRect:v.bounds toView:nil];
	return CGRectContainsPoint(v.window.bounds, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)));
}

// NowPlayingHostingController.viewModel. It subclasses a Swift generic (UIHostingController<T>),
// so its ivar list may not be exposed: then scan its fields for a NowPlayingViewModel heap pointer.
static id RLViewModel(UIViewController *host) {
	void **slot = RLIvar(host, "viewModel");
	if (slot) return (__bridge id)*slot;
	Class vmClass = objc_getClass("_TtC10NowPlaying19NowPlayingViewModel");
	void **words = (__bridge void *)host;
	size_t n = class_getInstanceSize(object_getClass(host)) / sizeof(void *);
	for (size_t i = 1; vmClass && i < n; i++)
		if (words[i] && malloc_size(words[i]) >= 16 && object_getClass((__bridge id)words[i]) == vmClass) return (__bridge id)words[i];
	return nil;
}

// LyricsView's pull-down-to-dismiss bridge holds the SwiftUI lyrics ScrollView's UIScrollView
// in a Swift `weak var scrollView` — read it with the Swift runtime's weak load.
static UIScrollView *RLBridgeScroll(void) {
	static id __attribute__((ns_returns_retained)) (*weakLoad)(void *);
	static dispatch_once_t once;
	dispatch_once(&once, ^{ weakLoad = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong"); });
	void *slot = RLIvar(gBridge, "scrollView");
	id sv = slot && weakLoad ? weakLoad(slot) : nil;
	return [sv isKindOfClass:UIScrollView.class] ? sv : nil;
}

static UIScrollView *RLScanScroll(UIView *v) {
	UIScrollView *best = nil;
	for (UIView *s in v.subviews) {
		if (s.hidden || [s isKindOfClass:RLLyricsView.class]) continue;
		UIScrollView *c = RLScanScroll(s);
		if ([s isKindOfClass:UIScrollView.class]) {
			UIScrollView *sv = (UIScrollView *)s;
			if (sv.contentSize.width <= sv.bounds.size.width + 1 && sv.bounds.size.height > v.window.bounds.size.height * 0.3 && sv.bounds.size.height > c.bounds.size.height) c = sv;
		}
		if (c.bounds.size.height * c.bounds.size.width > best.bounds.size.height * best.bounds.size.width) best = c;
	}
	return best;
}

static UIScrollView *RLTidalLyrics(void) {
	if (RLOnScreen(gLegacy)) return RLScanScroll(gLegacy.view);
	if (!RLOnScreen(gHost)) return nil;
	bool *on = RLIvar(RLViewModel(gHost), "_isShowingLyrics");
	if (!on || !*on) return nil;
	UIScrollView *sv = RLBridgeScroll();
	return sv.window ? sv : RLScanScroll(gHost.view);
}

static void RLSync(void) {
	UIScrollView *tidal = RLBool(@"enabled", YES) && RLStore.shared.status == RLStatusOK ? RLTidalLyrics() : nil;
	if (gLyricsView && gLyricsView.tidal != tidal) [gLyricsView detach];
	if (tidal && !gLyricsView.superview) {
		gLyricsView = [RLLyricsView attachTo:tidal];
		RLLog(@"attached over %@ %@", tidal.class, NSStringFromCGRect(tidal.frame));
		static int dumps;
		if (dumps++ < 2) {
			UIView *hv = gHost.viewIfLoaded;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (hv) RLDumpPlayer(hv); });
		}
	}
}

static __weak UIButton *gSettingsButton;

static void RLRewindVideos(CALayer *l, NSUInteger *n) {
	if ([l isKindOfClass:AVPlayerLayer.class]) {
		AVPlayer *p = ((AVPlayerLayer *)l).player;
		CMTime zero = { 0, 1, kCMTimeFlags_Valid, 0 };
		if (p) { [p seekToTime:zero toleranceBefore:zero toleranceAfter:zero]; (*n)++; }
	}
	for (CALayer *s in l.sublayers) RLRewindVideos(s, n);
}

void RLReplay(void) {
	[RLStore.shared seek:RLNum(@"offsetMs", 0) / 1000.0];
	[gBackdrop restart];
	[gLyricsView restart];
	NSUInteger n = 0;
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
		if ([sc isKindOfClass:UIWindowScene.class])
			for (UIWindow *w in ((UIWindowScene *)sc).windows) RLRewindVideos(w.layer, &n);
	RLLog(@"replay: song, backdrop, lyrics, %lu video cover(s) back to 0", (unsigned long)n);
}

void RLSettingsChanged(NSString *key) {
	if ([key isEqualToString:@"romanize"] || [key isEqualToString:@"synth"]) [RLStore.shared refetch];
	else if ([key isEqualToString:@"fontScale"]) [gLyricsView rebuild];
	else if ([key isEqualToString:@"tr"] || [key isEqualToString:@"trLang"]) { [gLyricsView rebuild]; [RLStore.shared translate]; }
	else if ([key isEqualToString:@"enabled"]) RLSync();
	else if ([key isEqualToString:@"backdrop"]) RLSyncBackdrop();
	else if ([key isEqualToString:@"fadeTint"]) { RLUntint(); RLSyncBackdrop(); }
	else if ([key isEqualToString:@"lang"]) {
		UIButtonConfiguration *c = gSettingsButton.configuration;
		c.title = RLL(@"Radiant Lyrics Settings", @"Radiant 가사 설정");
		gSettingsButton.configuration = c;
	}
}

static UITableView *RLFindTable(UIView *v) {
	if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
	for (UIView *s in v.subviews) {
		UITableView *t = RLFindTable(s);
		if (t) return t;
	}
	return nil;
}

static char kRLSettingsTable;

static UIView *RLSettingsFooter(UITableView *table, UIView *old) {
	CGFloat w = table.bounds.size.width, rowH = 76;
	UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, rowH + old.bounds.size.height)];
	footer.accessibilityIdentifier = @"rl.settings";
	UIButtonConfiguration *c = [UIButtonConfiguration tintedButtonConfiguration];
	c.title = RLL(@"Radiant Lyrics Settings", @"Radiant 가사 설정");
	c.image = [UIImage systemImageNamed:@"music.note.list"];
	c.imagePadding = 8;
	__weak UITableView *weakTable = table;
	UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { RLOpenSettings(weakTable.window.rootViewController); }]];
	gSettingsButton = b;
	b.frame = CGRectMake(16, 14, w - 32, 48);
	b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[footer addSubview:b];
	if (old) {
		old.frame = CGRectMake(0, rowH, w, old.bounds.size.height);
		old.autoresizingMask = UIViewAutoresizingFlexibleWidth;
		[footer addSubview:old];
	}
	return footer;
}

static void (*orig_setFooter)(UITableView *, SEL, UIView *);
static void hook_setFooter(UITableView *self, SEL _cmd, UIView *footer) {
	if (objc_getAssociatedObject(self, &kRLSettingsTable) && ![footer.accessibilityIdentifier isEqualToString:@"rl.settings"])
		footer = RLSettingsFooter(self, footer);
	orig_setFooter(self, _cmd, footer);
}

static void RLAddSettingsEntry(UIViewController *vc) {
	UITableView *table = RLFindTable(vc.view);
	if (!table) { RLLog(@"settings: no table view"); return; }
	objc_setAssociatedObject(table, &kRLSettingsTable, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	table.tableFooterView = table.tableFooterView; // goes through hook_setFooter
}

#pragma mark - Kawarp backdrop under TIDAL's player

static NSHashTable<CALayer *> *gHiddenBg;
static NSHashTable<CALayer *> *gHiddenFull;
static __weak UIView *gClearedView;
static UIColor *gClearedColor;

static BOOL RLSameColor(CGColorRef a, CGColorRef b) {
	if (!a || !b || CGColorGetNumberOfComponents(a) != CGColorGetNumberOfComponents(b)) return NO;
	const CGFloat *x = CGColorGetComponents(a), *y = CGColorGetComponents(b);
	for (size_t i = 0; i < CGColorGetNumberOfComponents(a); i++)
		if (fabs(x[i] - y[i]) > 0.02) return NO;
	return YES;
}

static void RLUnhideContainers(void) {
	for (CALayer *l in gHiddenBg.allObjects) {
		if (!l.sublayers.count) continue;
		[gHiddenBg removeObject:l];
		[gHiddenFull removeObject:l];
		l.hidden = NO;
		RLLog(@"backdrop: released %@ %@ (has sublayers)", l.class, NSStringFromCGRect(l.frame));
	}
}

static void RLHideBackground(CALayer *layer, CALayer *root, CGRect bounds, int depth) {
	for (CALayer *l in layer.sublayers) {
		if ([l.delegate isKindOfClass:RLLyricsView.class] || [l.delegate isKindOfClass:UIScrollView.class]) continue;
		if (l.sublayers.count) {
			if (depth < 12) RLHideBackground(l, root, bounds, depth + 1);
			continue;
		}
		if (l.hidden || [gHiddenBg containsObject:l]) continue;
		if ([l isKindOfClass:CAGradientLayer.class]) { RLCheckGradient((CAGradientLayer *)l); continue; }
		CGRect frame = [l convertRect:l.bounds toLayer:root], r = CGRectIntersection(frame, bounds);
		BOOL fill = l.backgroundColor && CGColorGetAlpha(l.backgroundColor) > 0.9 && !l.contents;
		BOOL image = l.contents && CFGetTypeID((__bridge CFTypeRef)l.contents) == CGImageGetTypeID();
		BOOL full = (fill || image) && r.size.width * r.size.height >= bounds.size.width * bounds.size.height * 0.9;
		BOOL patch = NO;
		for (CALayer *bg in gHiddenFull)
			if (fill) patch |= RLSameColor(bg.backgroundColor, l.backgroundColor);
		if (!full && !patch) continue;
		l.hidden = YES;
		[gHiddenBg addObject:l];
		if (full) [gHiddenFull addObject:l];
		RLLog(@"backdrop: hid TIDAL %@ %@ %@", full ? @"background" : @"patch", l.class, NSStringFromCGRect(frame));
	}
}

static void RLDumpLayers(CALayer *layer, CALayer *root, CGRect bounds, int depth, int *budget) {
	for (CALayer *l in layer.sublayers) {
		if (*budget <= 0) return;
		if (l.hidden || [l.delegate isKindOfClass:RLLyricsView.class] || [l.delegate isKindOfClass:UIScrollView.class]) continue;
		CGRect r = [l convertRect:l.bounds toLayer:root];
		if (r.size.width >= bounds.size.width * 0.9 && r.size.height < bounds.size.height * 0.9 && (l.contents || l.backgroundColor || l.filters.count || [l isKindOfClass:CAGradientLayer.class] || !l.sublayers.count)) {
			(*budget)--;
			NSString *what = l.contents ? (__bridge_transfer NSString *)CFCopyTypeIDDescription(CFGetTypeID((__bridge CFTypeRef)l.contents)) : @"-";
			RLLog(@"layer d%d %@ %@ bg%.2f op%.2f c:%@ sub%lu%@%@", depth, l.class, NSStringFromCGRect(r), l.backgroundColor ? CGColorGetAlpha(l.backgroundColor) : 0, l.opacity,
			      what, (unsigned long)l.sublayers.count, l.filters.count ? @" filters" : @"", [l isKindOfClass:CAGradientLayer.class] ? @" gradient" : @"");
		}
		if (depth < 12) RLDumpLayers(l, root, bounds, depth + 1, budget);
	}
}

static void RLDumpPlayer(UIView *hv) {
	int budget = 24;
	RLDumpLayers(hv.layer, hv.layer, hv.bounds, 0, &budget);
	NSMutableArray *chain = [NSMutableArray array];
	for (UIView *v = hv; v; v = v.superview) [chain addObject:[NSString stringWithFormat:@"%@%@", v.class, NSStringFromCGRect(v.frame)]];
	RLLog(@"player chain: %@", [chain componentsJoinedByString:@" < "]);
	NSArray *subs = hv.superview.subviews;
	for (NSUInteger i = [subs indexOfObjectIdenticalTo:hv] + 1; i < subs.count; i++)
		RLLog(@"above player: %@ %@", [subs[i] class], NSStringFromCGRect([subs[i] frame]));
	RLLog(@"backdrop: %@ in %@ %@", gBackdrop ? @"present" : @"MISSING", gBackdrop.superview.class, NSStringFromCGRect(gBackdrop.frame));
}

static CGColorRef gBgColor;

static BOOL RLSameRGB(CGColorRef a, CGColorRef b) {
	if (!a || !b || CGColorGetNumberOfComponents(a) != CGColorGetNumberOfComponents(b)) return NO;
	const CGFloat *x = CGColorGetComponents(a), *y = CGColorGetComponents(b);
	for (size_t i = 0; i + 1 < CGColorGetNumberOfComponents(a); i++)
		if (fabs(x[i] - y[i]) > 0.02) return NO;
	return YES;
}

static void RLHideNow(CALayer *l, NSString *what) {
	if (l.bounds.size.width < 100 || l.bounds.size.height < 8) return;
	l.hidden = YES;
	[gHiddenBg addObject:l];
	RLLog(@"backdrop: hid TIDAL %@ %@", what, NSStringFromCGRect(l.frame));
}

static void (*orig_setColors)(CAGradientLayer *, SEL, NSArray *);
static NSMapTable<CAGradientLayer *, NSArray *> *gTinted;

static CGFloat RLHueGap(CGColorRef a, UIColor *b) {
	CGFloat h1, s1, h2, s2, x;
	if (![[UIColor colorWithCGColor:a] getHue:&h1 saturation:&s1 brightness:&x alpha:&x] || ![b getHue:&h2 saturation:&s2 brightness:&x alpha:&x]) return 180;
	if (s1 < 0.15 || s2 < 0.15) return s1 < 0.15 && s2 < 0.15 ? 0 : 180;
	CGFloat d = fabs(h1 - h2);
	return MIN(d, 1 - d) * 360;
}

static void RLTint(CAGradientLayer *g, NSArray *colors) {
	UIColor *avg = gBackdrop.avgColor;
	if (!avg || !colors.count || !RLBool(@"fadeTint", YES)) return;
	if (!gTinted) gTinted = [NSMapTable weakToStrongObjectsMapTable];
	[gTinted setObject:colors forKey:g];
	CGColorRef tidal = NULL;
	for (id c in colors)
		if (!tidal || CGColorGetAlpha((__bridge CGColorRef)c) > CGColorGetAlpha(tidal)) tidal = (__bridge CGColorRef)c;
	CGFloat gap = RLHueGap(tidal, avg);
	NSMutableArray *out = [NSMutableArray array];
	for (id c in colors) [out addObject:(id)[avg colorWithAlphaComponent:CGColorGetAlpha((__bridge CGColorRef)c)].CGColor];
	NSArray *want = gap < 30 ? colors : out;
	if ([g.colors isEqualToArray:want]) return;
	orig_setColors(g, @selector(setColors:), want);
	RLLog(@"bottom fade: %@ (hue gap %.0f)", want == colors ? @"TIDAL color" : @"backdrop color", gap);
}

static void RLUntint(void) {
	for (CAGradientLayer *g in gTinted.keyEnumerator.allObjects) orig_setColors(g, @selector(setColors:), [gTinted objectForKey:g]);
	[gTinted removeAllObjects];
}

static void RLCheckGradient(CAGradientLayer *g) {
	if (!pthread_main_np() || !gClearedView || !gBgColor || [gHiddenBg containsObject:g]) return;
	if (fabs(g.startPoint.x - g.endPoint.x) > 0.01 || g.startPoint.y == g.endPoint.y) return;
	NSArray *cs = g.colors;
	if (cs.count < 2) return;
	BOOL down = g.startPoint.y <= g.endPoint.y;
	CGColorRef top = (__bridge CGColorRef)(down ? cs.firstObject : cs.lastObject), bottom = (__bridge CGColorRef)(down ? cs.lastObject : cs.firstObject);
	if (CGColorGetAlpha(top) > 0.5 && CGColorGetAlpha(bottom) < 0.1 && RLSameRGB(top, gBgColor)) RLHideNow(g, @"top fade");
	else if (CGColorGetAlpha(top) < 0.1 && CGColorGetAlpha(bottom) > 0.5 && RLSameRGB(bottom, gBgColor)) RLTint(g, cs);
}

// The fade checks compare against gBgColor, so whenever it changes rescan: a gradient checked
// against the old color would otherwise stay visible until the next poll.
static void RLSetBgColor(CGColorRef c) {
	if (!c || c == gBgColor) return;
	BOOL same = gBgColor && RLSameColor(c, gBgColor);
	CGColorRetain(c);
	CGColorRelease(gBgColor);
	gBgColor = c;
	if (!same && gClearedView) RLHideBackground(gClearedView.layer, gClearedView.layer, gClearedView.bounds, 0);
}

static void (*orig_setBG)(CALayer *, SEL, CGColorRef);
static void hook_setBG(CALayer *self, SEL _cmd, CGColorRef c) {
	orig_setBG(self, _cmd, c);
	if (!gClearedView || !c || !pthread_main_np()) return;
	if ([gHiddenFull containsObject:self]) { RLSetBgColor(c); return; }
	if (gBgColor && !self.contents && !self.sublayers.count && CGColorGetAlpha(c) > 0.9 && RLSameColor(c, gBgColor) && ![gHiddenBg containsObject:self]) RLHideNow(self, @"patch");
}

static void hook_setColors(CAGradientLayer *self, SEL _cmd, NSArray *colors) {
	orig_setColors(self, _cmd, colors);
	if (pthread_main_np() && [gTinted objectForKey:self]) RLTint(self, colors);
	else RLCheckGradient(self);
}
static void (*orig_setStart)(CAGradientLayer *, SEL, CGPoint);
static void hook_setStart(CAGradientLayer *self, SEL _cmd, CGPoint p) { orig_setStart(self, _cmd, p); RLCheckGradient(self); }
static void (*orig_setEnd)(CAGradientLayer *, SEL, CGPoint);
static void hook_setEnd(CAGradientLayer *self, SEL _cmd, CGPoint p) { orig_setEnd(self, _cmd, p); RLCheckGradient(self); }
static void (*orig_gSetBounds)(CAGradientLayer *, SEL, CGRect);
static void hook_gSetBounds(CAGradientLayer *self, SEL _cmd, CGRect r) { orig_gSetBounds(self, _cmd, r); RLCheckGradient(self); }
static void (*orig_gSetFrame)(CAGradientLayer *, SEL, CGRect);
static void hook_gSetFrame(CAGradientLayer *self, SEL _cmd, CGRect r) { orig_gSetFrame(self, _cmd, r); RLCheckGradient(self); }

static void (*orig_setHidden)(CALayer *, SEL, BOOL);
static void hook_setHidden(CALayer *self, SEL _cmd, BOOL hidden) {
	if (!hidden && gClearedView && pthread_main_np() && [gHiddenBg containsObject:self]) return;
	orig_setHidden(self, _cmd, hidden);
}

static void RLRestoreBackground(void) {
	NSArray *hidden = gHiddenBg.allObjects;
	[gHiddenBg removeAllObjects];
	[gHiddenFull removeAllObjects];
	for (CALayer *l in hidden) l.hidden = NO;
	RLUntint();
	gClearedView.backgroundColor = gClearedColor;
	gClearedView = nil;
	gClearedColor = nil;
	CGColorRelease(gBgColor);
	gBgColor = NULL;
}

static CGImageRef RLFindArtwork(CALayer *layer, CALayer *root, CGFloat *best) {
	CGImageRef found = NULL;
	for (CALayer *l in layer.sublayers) {
		if (l.hidden) continue;
		CGRect r = [l convertRect:l.bounds toLayer:root];
		if (l.contents && CFGetTypeID((__bridge CFTypeRef)l.contents) == CGImageGetTypeID() && r.size.width >= 40 && r.size.width < root.bounds.size.width * 0.95 &&
		    fabs(r.size.width - r.size.height) < 2 && r.size.width > *best) {
			*best = r.size.width;
			found = (__bridge CGImageRef)l.contents;
		}
		CGImageRef deeper = RLFindArtwork(l, root, best);
		if (deeper) found = deeper;
	}
	return found;
}

static RLBackdrop *RLMakeBackdrop(void) {
	if (!gBackdrop && RLBool(@"backdrop", YES)) {
		RLBackdrop *b = [[RLBackdrop alloc] initWithFrame:UIScreen.mainScreen.bounds];
		if (b.ready) {
			gBackdrop = b;
			[b setCover:RLStore.shared.artwork];
		}
	}
	return gBackdrop;
}

static void RLSyncBackdrop(void) {
	UIView *hv = gHost.viewIfLoaded;
	if (!hv.superview || !RLOnScreen(gHost) || !RLBool(@"backdrop", YES)) {
		[gBackdrop removeFromSuperview];
		RLRestoreBackground();
		return;
	}
	if (!gHiddenBg) gHiddenBg = [NSHashTable weakObjectsHashTable], gHiddenFull = [NSHashTable weakObjectsHashTable];
	if (!RLMakeBackdrop()) return;
	UIImage *cover = RLStore.shared.artwork;
	if (!cover) {
		CGFloat best = 0;
		CGImageRef art = RLFindArtwork(hv.layer, hv.layer, &best);
		static CGImageRef lastArt;
		if (art && art != lastArt) { lastArt = art; cover = [UIImage imageWithCGImage:art]; }
	}
	if (cover) [gBackdrop setCover:cover];
	gBackdrop.follow = hv;
	NSArray *subs = hv.superview.subviews;
	NSUInteger i = [subs indexOfObjectIdenticalTo:hv];
	if (gBackdrop.superview != hv.superview || i == 0 || subs[i - 1] != gBackdrop) [hv.superview insertSubview:gBackdrop belowSubview:hv];
	if (!gBackdrop.hasFrame) [gBackdrop tick];
	if (!gBackdrop.hasFrame) return;
	if (gClearedView != hv) {
		RLRestoreBackground();
		gClearedView = hv;
		gClearedColor = hv.backgroundColor;
	}
	hv.backgroundColor = UIColor.clearColor;
	RLUnhideContainers();
	RLHideBackground(hv.layer, hv.layer, hv.bounds, 0);
	RLSetBgColor(gHiddenFull.anyObject.backgroundColor);
	for (CAGradientLayer *g in gTinted.keyEnumerator.allObjects) RLTint(g, [gTinted objectForKey:g]);

	id vm = RLViewModel(gHost);
	bool *showing = RLIvar(vm, "_isShowingLyrics"), *full = RLIvar(vm, "_isFullLyrics");
	BOOL fullLyrics = showing && full && *showing && *full;
	static BOOL wasFull;
	if (fullLyrics && !wasFull) {
		static int dumps;
		if (dumps++ < 2) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ RLDumpPlayer(hv); });
	}
	wasFull = fullLyrics;
}

static void RLNoteTarget(id target) {
	if (target && strstr(class_getName(object_getClass(target)), "LyricsPullDownDismissBridge")) gBridge = target;
}

static id (*orig_grInit)(UIGestureRecognizer *, SEL, id, SEL);
static id hook_grInit(UIGestureRecognizer *self, SEL _cmd, id target, SEL action) {
	RLNoteTarget(target);
	return orig_grInit(self, _cmd, target, action);
}

static void (*orig_grAddTarget)(UIGestureRecognizer *, SEL, id, SEL);
static void hook_grAddTarget(UIGestureRecognizer *self, SEL _cmd, id target, SEL action) {
	RLNoteTarget(target);
	orig_grAddTarget(self, _cmd, target, action);
}

static void RLPollUpdate(void) {
	BOOL want = gHost || gLegacy;
	if (want && !gPoll) gPoll = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { RLSync(); RLSyncBackdrop(); }];
	if (!want) { [gPoll invalidate]; gPoll = nil; }
	RLSync();
	RLSyncBackdrop();
}

static void (*orig_viewWillAppear)(UIViewController *, SEL, BOOL);
static void hook_viewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewWillAppear(self, _cmd, animated);
	if (!strstr(class_getName(object_getClass(self)), "NowPlayingHostingController")) return;
	gHost = self;
	RLPollUpdate();
	dispatch_async(dispatch_get_main_queue(), ^{ RLSyncBackdrop(); });
}

static void (*orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void hook_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewDidAppear(self, _cmd, animated);
	const char *name = class_getName(object_getClass(self));
	if (strstr(name, "NowPlayingHostingController")) {
		gHost = self;
		id vm = RLViewModel(self);
		RLLog(@"player shown, viewModel %@, _isShowingLyrics %s", vm ? @"found" : @"MISSING", RLIvar(vm, "_isShowingLyrics") ? "found" : "MISSING");
		RLPollUpdate();
	} else if (strstr(name, "LyricsScene")) {
		gLegacy = self;
		RLPollUpdate();
	} else if ([self isKindOfClass:objc_getClass("_TtC4WiMP13SettingsScene")]) {
		RLAddSettingsEntry(self);
	}
}

static void (*orig_viewDidDisappear)(UIViewController *, SEL, BOOL);
static void hook_viewDidDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewDidDisappear(self, _cmd, animated);
	if (self == gHost) gHost = nil;
	else if (self == gLegacy) gLegacy = nil;
	else return;
	RLPollUpdate();
}

static void RLShake(void) {
	static double last;
	double now = CACurrentMediaTime();
	if (now - last < 1.5) return;
	last = now;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
		if ([scene isKindOfClass:UIWindowScene.class])
			for (UIWindow *w in ((UIWindowScene *)scene).windows)
				if (w.isKeyWindow) { RLOpenSettings(w.rootViewController); return; }
}

static void (*orig_shakeState)(id, SEL, int);
static void hook_shakeState(id self, SEL _cmd, int state) {
	orig_shakeState(self, _cmd, state);
	if (state == 1) RLShake();
}

__attribute__((constructor)) static void RLInit(void) {
	[NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		if (RLBool(@"replayOnRecord", NO) && ((UIScreen *)n.object).isCaptured) RLReplay();
	}];
	RLHook(MPNowPlayingInfoCenter.class, @selector(setNowPlayingInfo:), (IMP)hook_setInfo, (IMP *)&orig_setInfo);
	RLHook(MPRemoteCommand.class, @selector(addTargetWithHandler:), (IMP)hook_addHandler, (IMP *)&orig_addHandler);
	RLHook(MPRemoteCommand.class, @selector(addTarget:action:), (IMP)hook_addTarget, (IMP *)&orig_addTarget);
	RLHook(MPRemoteCommand.class, @selector(removeTarget:), (IMP)hook_removeTarget, (IMP *)&orig_removeTarget);
	RLHook(UIGestureRecognizer.class, @selector(initWithTarget:action:), (IMP)hook_grInit, (IMP *)&orig_grInit);
	RLHook(UIGestureRecognizer.class, @selector(addTarget:action:), (IMP)hook_grAddTarget, (IMP *)&orig_grAddTarget);
	RLHook(UIViewController.class, @selector(viewWillAppear:), (IMP)hook_viewWillAppear, (IMP *)&orig_viewWillAppear);
	RLHook(UIViewController.class, @selector(viewDidAppear:), (IMP)hook_viewDidAppear, (IMP *)&orig_viewDidAppear);
	RLHook(UIViewController.class, @selector(viewDidDisappear:), (IMP)hook_viewDidDisappear, (IMP *)&orig_viewDidDisappear);
	RLHook(objc_getClass("UIMotionEvent"), @selector(setShakeState:), (IMP)hook_shakeState, (IMP *)&orig_shakeState);
	RLHook(UITableView.class, @selector(setTableFooterView:), (IMP)hook_setFooter, (IMP *)&orig_setFooter);
	RLHook(CALayer.class, @selector(setBackgroundColor:), (IMP)hook_setBG, (IMP *)&orig_setBG);
	RLHook(CALayer.class, @selector(setHidden:), (IMP)hook_setHidden, (IMP *)&orig_setHidden);
	RLHook(CAGradientLayer.class, @selector(setColors:), (IMP)hook_setColors, (IMP *)&orig_setColors);
	RLHook(CAGradientLayer.class, @selector(setStartPoint:), (IMP)hook_setStart, (IMP *)&orig_setStart);
	RLHook(CAGradientLayer.class, @selector(setEndPoint:), (IMP)hook_setEnd, (IMP *)&orig_setEnd);
	RLHook(CAGradientLayer.class, @selector(setBounds:), (IMP)hook_gSetBounds, (IMP *)&orig_gSetBounds);
	RLHook(CAGradientLayer.class, @selector(setFrame:), (IMP)hook_gSetFrame, (IMP *)&orig_gSetFrame);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ RLMakeBackdrop(); });
	RLLog(@"loaded");
}
