#import "RL.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>

static const CGFloat kPad = 14;

static UIFont *RLFont(NSString *name, CGFloat size, UIFontWeight weight) {
	return [UIFont fontWithName:name size:size] ?: [UIFont systemFontOfSize:size weight:weight];
}

static NSString *RLTrimEnd(NSString *s) {
	NSRange r = [s rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet.invertedSet options:NSBackwardsSearch];
	return r.location == NSNotFound ? @"" : [s substringToIndex:NSMaxRange(r)];
}

#pragma mark - Line view: each text block drawn once, dim copy + bright copy under a per-syllable wipe

@interface RLSlot : NSObject {
@public
	RLSyl *syl;
	NSString *text;
	CGFloat textWidth, advance;
	CGRect rect;
	CAGradientLayer *wipe;
	CGFloat p, o;
	double ws, we;
}
@end
@implementation RLSlot
@end

@interface RLTextView : UIView
@property (nonatomic, copy) NSArray<RLSlot *> *slots;
@property (nonatomic, copy) NSDictionary *attrs;
@property (nonatomic) CGFloat blur;
@end
@implementation RLTextView
- (void)drawRect:(CGRect)dirty {
	// Blurred lines are drawn as their own shadow: the glyphs land off to the left, outside the clip,
	// and only the shadow (offset back by the same amount) shows. Painting them in clear instead
	// would draw nothing at all -- a shadow comes from the alpha that was drawn.
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGFloat shift = 0;
	if (_blur > 0) {
		UIColor *c = _attrs[NSForegroundColorAttributeName] ?: UIColor.whiteColor;
		shift = self.bounds.size.width + 4 * _blur + 20;
		CGContextSaveGState(ctx);
		CGContextClipToRect(ctx, self.bounds);
		CGContextSetShadowWithColor(ctx, CGSizeMake(shift, 0), _blur, c.CGColor);
	}
	for (RLSlot *s in _slots) [s->text drawAtPoint:CGPointMake(s->rect.origin.x + kPad - shift, s->rect.origin.y + kPad) withAttributes:_attrs];
	if (shift > 0) CGContextRestoreGState(ctx);
}
- (void)setBlur:(CGFloat)blur {
	if (blur == _blur) return;
	_blur = blur;
	if (!self.hidden) [self setNeedsDisplay];
}
@end

static void RLSetWipe(RLSlot *s, CGFloat p) {
	s->wipe.hidden = p <= 0;
	CGFloat f = MIN(0.5, s->wipe.frame.size.height * 0.4 / MAX(1, s->wipe.frame.size.width));
	CGFloat edge = -f + p * (1 + f);
	s->wipe.locations = @[ @0, @(MAX(0, MIN(1, edge))), @(MAX(0, MIN(1, edge + f))), @1 ];
}

static void RLSetOn(RLSlot *s, CGFloat o, BOOL animated) {
	if (animated) {
		CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
		a.fromValue = @(s->wipe.presentationLayer ? s->wipe.presentationLayer.opacity : s->wipe.opacity);
		a.toValue = @(o);
		a.duration = 0.15;
		a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
		[s->wipe addAnimation:a forKey:@"on"];
	} else [s->wipe removeAnimationForKey:@"on"];
	s->wipe.opacity = o;
	s->o = o;
}

@interface RLBlock : NSObject
@property (nonatomic, readonly) CGFloat height;
- (instancetype)initWithSyls:(NSArray<RLSyl *> *)syls font:(UIFont *)font width:(CGFloat)width right:(BOOL)right in:(UIView *)box y:(CGFloat)y;
- (void)update:(double)t glow:(CGFloat)glow style:(NSInteger)style;
- (void)setBlur:(CGFloat)blur;
- (void)fadeOut;
- (void)setDrawn:(BOOL)drawn;
@end

@implementation RLBlock {
	NSMutableArray<RLSlot *> *_slots;
	RLTextView *_base, *_hi;
	UIView *_glow;
	NSUInteger _gen;
	BOOL _drawn;
}

static NSMutableArray<RLSlot *> *RLMeasure(NSArray<RLSyl *> *syls, NSDictionary *attrs, CGFloat width) {
	NSMutableString *all = [NSMutableString string];
	NSMutableArray *starts = [NSMutableArray array];
	for (RLSyl *s in syls) { [starts addObject:@(all.length)]; [all appendString:s.text]; }
	CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:all attributes:attrs]);
	NSMutableArray<RLSlot *> *slots = [NSMutableArray array];
	void (^add)(RLSyl *, NSUInteger, NSString *) = ^(RLSyl *syl, NSUInteger at, NSString *text) {
		RLSlot *s = [RLSlot new];
		s->syl = syl;
		s->text = RLTrimEnd(text);
		CGFloat x0 = CTLineGetOffsetForStringIndex(line, at, NULL);
		s->textWidth = ceil(CTLineGetOffsetForStringIndex(line, at + s->text.length, NULL) - x0);
		s->advance = CTLineGetOffsetForStringIndex(line, at + text.length, NULL) - x0;
		[slots addObject:s];
	};
	[syls enumerateObjectsUsingBlock:^(RLSyl *syl, NSUInteger i, BOOL *stop) {
		NSUInteger at = [starts[i] unsignedIntegerValue];
		CGFloat w = CTLineGetOffsetForStringIndex(line, at + RLTrimEnd(syl.text).length, NULL) - CTLineGetOffsetForStringIndex(line, at, NULL);
		if (w > width && syl.text.length > 1)
			[syl.text enumerateSubstringsInRange:NSMakeRange(0, syl.text.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *c, NSRange r, NSRange er, BOOL *st) { add(syl, at + r.location, c); }];
		else
			add(syl, at, syl.text);
	}];
	CFRelease(line);
	return slots;
}

static CGFloat RLWordWidth(NSArray<RLSlot *> *word) {
	CGFloat w = word.lastObject->textWidth;
	for (NSUInteger i = 0; i + 1 < word.count; i++) w += word[i]->advance;
	return w;
}

static CGFloat RLRowWidth(NSArray<NSArray<RLSlot *> *> *row) {
	CGFloat w = 0;
	for (NSArray<RLSlot *> *word in row)
		for (RLSlot *s in word) w += s->advance;
	return w - row.lastObject.lastObject->advance + row.lastObject.lastObject->textWidth;
}

- (instancetype)initWithSyls:(NSArray<RLSyl *> *)syls font:(UIFont *)font width:(CGFloat)width right:(BOOL)right in:(UIView *)box y:(CGFloat)y0 {
	if (!(self = [super init])) return nil;
	NSDictionary *attrs = @{ NSFontAttributeName: font, NSKernAttributeName: @(-0.02 * font.pointSize) };
	_slots = RLMeasure(syls, attrs, width);

	NSMutableArray<NSArray<RLSlot *> *> *words = [NSMutableArray array];
	NSMutableArray<RLSlot *> *word = [NSMutableArray array];
	for (RLSlot *s in _slots) {
		[word addObject:s];
		if (s->advance > s->textWidth + 0.5 || s == _slots.lastObject) { [words addObject:word]; word = [NSMutableArray array]; }
	}
	for (NSArray<RLSlot *> *w in words) {
		double we = w.firstObject->syl.start;
		for (RLSlot *s in w) we = MAX(we, s->syl.end);
		for (RLSlot *s in w) s->ws = w.firstObject->syl.start, s->we = we;
	}
	NSMutableArray<NSMutableArray<NSArray<RLSlot *> *> *> *rows = [NSMutableArray arrayWithObject:[NSMutableArray array]];
	CGFloat x = 0;
	for (NSArray<RLSlot *> *w in words)
		for (NSArray<RLSlot *> *piece in (RLWordWidth(w) > width ? [w valueForKey:@"self"] : @[ w ])) {
			NSArray<RLSlot *> *p = [piece isKindOfClass:NSArray.class] ? piece : @[ (RLSlot *)piece ];
			if (x > 0 && x + RLWordWidth(p) > width) { [rows addObject:[NSMutableArray array]]; x = 0; }
			[rows.lastObject addObject:p];
			for (RLSlot *s in p) x += s->advance;
		}
	NSUInteger n = rows.count;
	if (n >= 2 && rows[n - 1].count == 1 && rows[n - 2].count >= 2) {
		NSMutableArray *last = [rows[n - 1] mutableCopy];
		[last insertObject:rows[n - 2].lastObject atIndex:0];
		if (RLRowWidth(last) <= width) { [rows[n - 2] removeLastObject]; rows[n - 1] = last; }
	}

	CGFloat rowH = round(font.pointSize * 1.235), lineH = ceil(font.lineHeight), y = 0;
	for (NSArray<NSArray<RLSlot *> *> *row in rows) {
		x = right ? width - RLRowWidth(row) : 0;
		for (NSArray<RLSlot *> *w in row)
			for (RLSlot *s in w) {
				s->rect = CGRectMake(x, y + (rowH - lineH) / 2, s->textWidth, lineH);
				x += s->advance;
			}
		y += rowH;
	}
	_height = y;

	CGRect frame = CGRectMake(-kPad, y0 - kPad, width + 2 * kPad, y + 2 * kPad);
	RLTextView *(^text)(CGFloat) = ^(CGFloat alpha) {
		RLTextView *v = [[RLTextView alloc] initWithFrame:frame];
		v.opaque = NO;
		v.backgroundColor = UIColor.clearColor;
		v.userInteractionEnabled = NO;
		v.slots = self->_slots;
		NSMutableDictionary *a = [attrs mutableCopy];
		a[NSForegroundColorAttributeName] = [UIColor colorWithWhite:1 alpha:alpha];
		v.attrs = a;
		return v;
	};
	_base = text(0.3);
	_hi = text(1);
	_hi.frame = (CGRect){ CGPointZero, frame.size };
	CALayer *mask = [CALayer layer];
	mask.frame = _hi.bounds;
	for (RLSlot *s in _slots) {
		s->wipe = [CAGradientLayer layer];
		s->wipe.frame = CGRectMake(s->rect.origin.x + kPad, s->rect.origin.y + kPad - (rowH - lineH) / 2, s->rect.size.width, rowH);
		s->wipe.startPoint = CGPointMake(0, 0.5);
		s->wipe.endPoint = CGPointMake(1, 0.5);
		s->wipe.colors = @[ (id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor, (id)UIColor.clearColor.CGColor ];
		RLSetWipe(s, 0);
		s->wipe.opacity = 0;
		[mask addSublayer:s->wipe];
	}
	_hi.layer.mask = mask;
	_glow = [[UIView alloc] initWithFrame:frame];
	_glow.userInteractionEnabled = NO;
	_glow.layer.shadowColor = UIColor.whiteColor.CGColor;
	_glow.layer.shadowOffset = CGSizeZero;
	_glow.layer.shadowRadius = font.pointSize * 0.3;
	[_glow addSubview:_hi];
	[box addSubview:_base];
	[box addSubview:_glow];
	_drawn = YES;
	[self setDrawn:NO];
	return self;
}

- (void)setBlur:(CGFloat)blur {
	_base.blur = _hi.blur = blur;
}

- (void)setDrawn:(BOOL)drawn {
	if (drawn == _drawn) return;
	_drawn = drawn;
	for (RLTextView *v in @[ _base, _hi ]) {
		v.hidden = !drawn;
		if (drawn) [v setNeedsDisplay];
		else v.layer.contents = nil;
	}
}

- (void)update:(double)t glow:(CGFloat)glow style:(NSInteger)style {
	_gen++;
	if (_glow.alpha < 1) { [_glow.layer removeAllAnimations]; _glow.alpha = 1; }
	BOOL lit = NO;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for (RLSlot *s in _slots) {
		CGFloat p = 1, o = 1;
		if (style >= 2) {
			double len = s->syl.end - s->syl.start;
			p = len > 0.01 ? MAX(0, MIN(1, (t - s->syl.start) / len)) : (t >= s->syl.start ? 1 : 0);
		} else if (style == 1)
			o = t >= s->ws && (t <= s->we || s->we - s->ws < 0.01);
		lit |= p > 0 && o > 0;
		if (p != s->p) { s->p = p; RLSetWipe(s, p); }
		if (o != s->o) RLSetOn(s, o, style < 2);
	}
	_glow.layer.shadowOpacity = lit ? glow : 0;
	[CATransaction commit];
}

- (void)fadeOut {
	NSUInteger gen = ++_gen;
	[UIView animateWithDuration:0.5 animations:^{ self->_glow.alpha = 0; } completion:^(BOOL finished) {
		if (gen != self->_gen) return;
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		for (RLSlot *s in self->_slots) {
			if (s->p != 0) { s->p = 0; RLSetWipe(s, 0); }
			if (s->o != 0) RLSetOn(s, 0, NO);
		}
		self->_glow.layer.shadowOpacity = 0;
		[CATransaction commit];
		self->_glow.alpha = 1;
	}];
}
@end

@interface RLLineView : UIView
@property (nonatomic, strong) RLLine *line;
@property (nonatomic) CGFloat top;
@property (nonatomic) BOOL active;
@property (nonatomic, readonly) CGFloat height;
- (void)update:(double)t glow:(CGFloat)glow style:(NSInteger)style;
- (void)setDrawn:(BOOL)drawn;
- (void)setBlurEm:(CGFloat)em;
@end

static UIViewPropertyAnimator *RLEase(NSTimeInterval d, void (^animations)(void)) {
	UIViewPropertyAnimator *a = [[UIViewPropertyAnimator alloc] initWithDuration:d timingParameters:[[UICubicTimingParameters alloc] initWithControlPoint1:CGPointMake(0.25, 0.1) controlPoint2:CGPointMake(0.25, 1)]];
	[a addAnimations:animations];
	[a startAnimation];
	return a;
}

@implementation RLLineView {
	RLBlock *_main, *_bgBlock, *_trBlock;
	UIView *_bgBox, *_trBox;
	CGFloat _bgH, _trH, _trPad, _size, _blur;
}

- (instancetype)initWithLine:(RLLine *)line width:(CGFloat)width size:(CGFloat)size {
	if ((self = [super initWithFrame:CGRectZero])) {
		_line = line;
		_size = size;
		_main = [[RLBlock alloc] initWithSyls:line.main font:RLFont(@"SquareSansDisplay-Bold", size, UIFontWeightBold) width:width right:line.right in:self y:0];
		if (line.bg.count) {
			CGFloat bgSize = size * 0.55, pad = round(bgSize * 0.15);
			_bgBox = [[UIView alloc] init];
			_bgBox.userInteractionEnabled = NO;
			_bgBox.alpha = 0;
			_bgBlock = [[RLBlock alloc] initWithSyls:line.bg font:RLFont(@"SquareSansText-SemiBold", bgSize, UIFontWeightSemibold) width:width right:line.right in:_bgBox y:0];
			_bgBox.frame = CGRectMake(0, _main.height + pad, width, _bgBlock.height);
			[self addSubview:_bgBox];
			_bgH = pad + _bgBlock.height;
		}
		NSArray<RLSyl *> *tr = RLTrFor(line);
		if (tr.count) {
			CGFloat trSize = size * 0.6;
			_trPad = round(trSize * 0.3);
			_trBox = [[UIView alloc] init];
			_trBox.userInteractionEnabled = NO;
			_trBlock = [[RLBlock alloc] initWithSyls:tr font:RLFont(@"SquareSansText-SemiBold", trSize, UIFontWeightSemibold) width:width right:line.right in:_trBox y:0];
			_trBox.frame = CGRectMake(0, _main.height + _trPad, width, _trBlock.height);
			[self addSubview:_trBox];
			_trH = _trPad + _trBlock.height;
		}
		self.layer.anchorPoint = CGPointMake(line.right ? 1 : 0, 0.5);
		self.bounds = CGRectMake(0, 0, width, _main.height + _trH);
		self.alpha = 0.7;
		self.transform = CGAffineTransformMakeScale(0.96, 0.96);
	}
	return self;
}

- (void)update:(double)t glow:(CGFloat)glow style:(NSInteger)style {
	[_main update:t glow:glow style:style];
	[_bgBlock update:t glow:glow style:style];
	[_trBlock update:t glow:0 style:0];
}

// Plugin's "filter: blur(Nem)" on inactive lines. CALayer.filters is not supported on iOS
// (it blanks the layer), so the text itself is drawn blurred instead.
- (void)setBlurEm:(CGFloat)em {
	CGFloat r = round(em * _size * 2) / 2;
	if (r == _blur) return;
	_blur = r;
	[_main setBlur:r];
	[_bgBlock setBlur:r];
	[_trBlock setBlur:r];
}

- (void)setDrawn:(BOOL)drawn {
	[_main setDrawn:drawn];
	[_bgBlock setDrawn:drawn];
	[_trBlock setDrawn:drawn];
}

- (void)setActive:(BOOL)active {
	if (active == _active) return;
	_active = active;
	[UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
		self.alpha = active ? 1 : 0.7;
		self.transform = active ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.96, 0.96);
	} completion:nil];
	if (!active) { [_main fadeOut]; [_bgBlock fadeOut]; [_trBlock fadeOut]; }
	UIView *bg = _bgBox, *tr = _trBox;
	CGFloat trY = _main.height + (active ? _bgH : 0) + _trPad;
	if (bg || tr) RLEase(0.5, ^{
		bg.alpha = active;
		tr.frame = (CGRect){ CGPointMake(0, trY), tr.frame.size };
	});
}

- (CGFloat)height { return _main.height + _trH + (_active ? _bgH : 0); }
@end

#pragma mark - Settings sheet (long-press the lyrics)

@interface RLSettingsViewController : UIViewController
@end

@implementation RLSettingsViewController {
	UIStackView *_stack;
	UILabel *_offsetLabel;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
	self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	UIScrollView *scroll = [UIScrollView new];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:scroll];
	_stack = [UIStackView new];
	_stack.axis = UILayoutConstraintAxisVertical;
	_stack.spacing = 18;
	_stack.translatesAutoresizingMaskIntoConstraints = NO;
	[scroll addSubview:_stack];
	[NSLayoutConstraint activateConstraints:@[
		[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
		[_stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
		[_stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:22],
		[_stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-22],
	]];
	[self build];
}

- (void)build {
	for (UIView *v in _stack.arrangedSubviews) [v removeFromSuperview];
	UILabel *title = [UILabel new];
	title.text = RLL(@"Radiant Lyrics", @"Radiant 가사");
	title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
	[_stack addArrangedSubview:title];

	UISegmentedControl *lang = [[UISegmentedControl alloc] initWithItems:@[ RLL(@"Auto", @"자동"), @"English", @"한국어" ]];
	lang.selectedSegmentIndex = (NSInteger)RLNum(@"lang", 0);
	[lang addAction:[UIAction actionWithHandler:^(UIAction *a) {
		RLSet(@"lang", @(((UISegmentedControl *)a.sender).selectedSegmentIndex));
		RLSettingsChanged(@"lang");
		dispatch_async(dispatch_get_main_queue(), ^{ [self build]; });
	}] forControlEvents:UIControlEventValueChanged];
	[self row:RLL(@"Language", @"언어") control:lang];

	[self toggle:@"enabled" title:RLL(@"Use Radiant Lyrics", @"Radiant 가사 사용") def:YES];
	[self toggle:@"backdrop" title:RLL(@"Custom Backdrop (Kawarp)", @"배경 효과 (Kawarp)") def:YES];
	[self toggle:@"motion" title:RLL(@"Animate Backdrop", @"배경 움직임") def:YES];
	[self toggle:@"romanize" title:RLL(@"Romanize Lyrics", @"로마자 표기") def:NO];
	[self toggle:@"tr" title:RLL(@"Show Translation", @"번역 표시") def:NO];
	NSLocale *names = [NSLocale localeWithLocaleIdentifier:RLL(@"en", @"ko")];
	NSMutableArray<UIAction *> *langs = [NSMutableArray array];
	for (NSString *code in kRLTrLangs) {
		UIAction *pick = [UIAction actionWithTitle:[names localizedStringForLanguageCode:code] ?: code image:nil identifier:nil handler:^(UIAction *a) {
			RLSet(@"trLang", code);
			RLSettingsChanged(@"trLang");
		}];
		pick.state = [code isEqualToString:RLTrLang()] ? UIMenuElementStateOn : UIMenuElementStateOff;
		[langs addObject:pick];
	}
	UIButton *trLang = [UIButton buttonWithConfiguration:[UIButtonConfiguration grayButtonConfiguration] primaryAction:nil];
	trLang.menu = [UIMenu menuWithChildren:langs];
	trLang.showsMenuAsPrimaryAction = YES;
	trLang.changesSelectionAsPrimaryAction = YES;
	[self row:RLL(@"Translation Language", @"번역 언어") control:trLang];
	[self toggle:@"synth" title:RLL(@"AI Word Sync (line-synced songs)", @"AI 단어 싱크 (줄 가사만 있는 곡)") def:NO];
	[self toggle:@"blurInactive" title:RLL(@"Blur Inactive", @"비활성 줄 흐리게") def:YES];
	[self toggle:@"bounce" title:RLL(@"Staggered Scroll (lines follow one by one)", @"줄이 하나씩 따라오는 스크롤") def:YES];
	[self toggle:@"replayOnRecord" title:RLL(@"Restart from 0 when screen recording starts", @"화면 녹화 시작하면 처음부터 다시 재생") def:NO];
	UISegmentedControl *style = [[UISegmentedControl alloc] initWithItems:@[ RLL(@"Line", @"줄"), RLL(@"Word", @"단어"), RLL(@"Syllable", @"음절") ]];
	style.selectedSegmentIndex = (NSInteger)RLNum(@"style", 2);
	[style addAction:[UIAction actionWithHandler:^(UIAction *a) { RLSet(@"style", @(((UISegmentedControl *)a.sender).selectedSegmentIndex)); }] forControlEvents:UIControlEventValueChanged];
	[self row:RLL(@"Lyrics Style", @"가사 스타일") control:style];
	[self slider:@"glow" title:RLL(@"Text Glow", @"글로우") min:0 max:1 def:0.6];
	[self slider:@"fontScale" title:RLL(@"Font Size (vs. original)", @"글자 크기 (원본 대비)") min:0.7 max:1.5 def:1.14];

	UIStepper *st = [UIStepper new];
	st.minimumValue = -2000;
	st.maximumValue = 2000;
	st.stepValue = 50;
	st.value = RLNum(@"offsetMs", 0);
	[st addAction:[UIAction actionWithHandler:^(UIAction *a) {
		RLSet(@"offsetMs", @(st.value));
		[self updateOffsetLabel];
	}] forControlEvents:UIControlEventValueChanged];
	_offsetLabel = [self row:@"" control:st];
	[self updateOffsetLabel];

	UIButtonConfiguration *lc = [UIButtonConfiguration grayButtonConfiguration];
	lc.title = RLL(@"Reload Lyrics", @"가사 다시 불러오기");
	__weak typeof(self) weakReload = self;
	[_stack addArrangedSubview:[UIButton buttonWithConfiguration:lc primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
		RLClearCache();
		[RLStore.shared refetch:YES];
		[weakReload dismissViewControllerAnimated:YES completion:nil];
	}]]];

	UIButtonConfiguration *pc = [UIButtonConfiguration grayButtonConfiguration];
	pc.title = RLL(@"Replay from Start (for recording)", @"처음부터 다시 재생 (녹화용)");
	[_stack addArrangedSubview:[UIButton buttonWithConfiguration:pc primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
		[weakReload dismissViewControllerAnimated:YES completion:^{ RLReplay(); }];
	}]]];

	UIButtonConfiguration *rc = [UIButtonConfiguration grayButtonConfiguration];
	rc.title = RLL(@"Reset to Defaults", @"기본값으로 초기화");
	rc.baseForegroundColor = UIColor.systemRedColor;
	__weak typeof(self) weakSelf = self;
	[_stack addArrangedSubview:[UIButton buttonWithConfiguration:rc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf confirmReset]; }]]];

	UILabel *hint = [UILabel new];
	hint.text = [RLL(@"Lyrics late? Tap +. Early? Tap −. Shake the device to open this sheet.", @"가사가 늦으면 +, 빠르면 −. 기기를 흔들면 이 창이 열려요.") stringByAppendingString:@"\nLyrics: Radiant Lyrics API (meowarex) · Korean translations: Musixmatch"];
	hint.numberOfLines = 0;
	hint.font = [UIFont systemFontOfSize:13];
	hint.textColor = UIColor.secondaryLabelColor;
	[_stack addArrangedSubview:hint];

	UILabel *logTitle = [UILabel new];
	logTitle.text = RLL(@"Recent log", @"최근 로그");
	logTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	logTitle.textColor = UIColor.secondaryLabelColor;
	[_stack addArrangedSubview:logTitle];
	UITextView *log = [UITextView new];
	log.editable = NO;
	log.scrollEnabled = NO;
	log.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
	log.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
	log.layer.cornerRadius = 8;
	log.text = [[[RLLogLines() reverseObjectEnumerator] allObjects] componentsJoinedByString:@"\n"] ?: @"";
	[_stack addArrangedSubview:log];
}

- (void)confirmReset {
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:RLL(@"Reset all settings?", @"설정을 모두 초기화할까요?") message:nil preferredStyle:UIAlertControllerStyleAlert];
	[ac addAction:[UIAlertAction actionWithTitle:RLL(@"Cancel", @"취소") style:UIAlertActionStyleCancel handler:nil]];
	__weak typeof(self) weakSelf = self;
	[ac addAction:[UIAlertAction actionWithTitle:RLL(@"Reset", @"초기화") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
		NSMutableArray<NSString *> *keys = [NSMutableArray array];
		for (NSString *k in RLDefaults.dictionaryRepresentation)
			if ([k hasPrefix:@"rl."]) [keys addObject:[k substringFromIndex:3]];
		for (NSString *k in keys) [RLDefaults removeObjectForKey:[@"rl." stringByAppendingString:k]];
		for (NSString *k in keys) RLSettingsChanged(k);
		[weakSelf build];
	}]];
	[self presentViewController:ac animated:YES completion:nil];
}

- (void)updateOffsetLabel {
	_offsetLabel.text = [NSString stringWithFormat:RLL(@"Sync Offset  %+.0fms", @"싱크 보정  %+.0fms"), RLNum(@"offsetMs", 0)];
}

- (UILabel *)row:(NSString *)text control:(UIView *)control {
	UILabel *l = [UILabel new];
	l.text = text;
	l.font = [UIFont systemFontOfSize:16];
	l.numberOfLines = 0;
	[l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	[control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ l, control ]];
	row.spacing = 12;
	row.alignment = UIStackViewAlignmentCenter;
	[_stack addArrangedSubview:row];
	return l;
}

- (void)toggle:(NSString *)key title:(NSString *)title def:(BOOL)def {
	UISwitch *sw = [UISwitch new];
	sw.on = RLBool(key, def);
	[sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
		RLSet(key, @(sw.on));
		RLSettingsChanged(key);
	}] forControlEvents:UIControlEventValueChanged];
	[self row:title control:sw];
}

- (void)slider:(NSString *)key title:(NSString *)title min:(float)min max:(float)max def:(float)def {
	UISlider *sl = [UISlider new];
	sl.minimumValue = min;
	sl.maximumValue = max;
	sl.value = RLNum(key, def);
	[sl.widthAnchor constraintEqualToConstant:160].active = YES;
	[sl addAction:[UIAction actionWithHandler:^(UIAction *a) { RLSet(key, @(sl.value)); }] forControlEvents:UIControlEventValueChanged];
	[sl addAction:[UIAction actionWithHandler:^(UIAction *a) {
		RLSettingsChanged(key);
	}] forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
	[self row:title control:sl];
}
@end

#pragma mark - Lyrics view

@interface RLLyricsView () <UIScrollViewDelegate>
- (void)tick;
@end

@interface RLDisplayProxy : NSObject
@property (nonatomic, weak) RLLyricsView *target;
@end
@implementation RLDisplayProxy
- (void)tick:(CADisplayLink *)link { [_target tick]; }
@end

@implementation RLLyricsView {
	UIScrollView *_scroll;
	CAGradientLayer *_fade;
	NSArray<RLLine *> *_lines;
	NSMutableArray<RLLineView *> *_lineViews;
	NSMutableIndexSet *_activeSet;
	NSInteger _focus;
	CGSize _builtSize;
	UIEdgeInsets _insets;
	CGFloat _tidalAlpha, _nativeSize, _nativeMargin, _anchor, _gap;
	BOOL _measured;
	BOOL _dragging;
	double _lastUserScroll;
	CADisplayLink *_link;
}

static void RLTextLayers(CALayer *layer, CALayer *root, NSMutableArray<NSValue *> *out, int depth) {
	if (depth > 14) return;
	for (CALayer *l in layer.sublayers) {
		CGRect r = [l convertRect:l.bounds toLayer:root];
		if (l.contents && r.size.height >= 14 && r.size.height <= 300 && r.size.width >= 20) [out addObject:[NSValue valueWithCGRect:r]];
		RLTextLayers(l, root, out, depth + 1);
	}
}

static BOOL RLMeasureNative(UIScrollView *tidal, CGFloat *size, CGFloat *margin) {
	NSMutableArray<NSValue *> *rects = [NSMutableArray array];
	RLTextLayers(tidal.layer, tidal.layer, rects, 0);
	NSCountedSet *heights = [NSCountedSet set];
	CGFloat minX = CGFLOAT_MAX;
	for (NSValue *v in rects) {
		[heights addObject:@(round(v.CGRectValue.size.height))];
		minX = MIN(minX, CGRectGetMinX(v.CGRectValue));
	}
	CGFloat line = 0;
	for (NSNumber *h in heights)
		if ([heights countForObject:h] >= 3 && (!line || h.doubleValue < line)) line = h.doubleValue;
	NSString *sample = [[RLStore.shared.lines.firstObject.main valueForKey:@"text"] componentsJoinedByString:@""];
	CGFloat ratio = ceil([sample.length ? sample : @"Ag" sizeWithAttributes:@{ NSFontAttributeName: RLFont(@"SquareSansDisplay-Bold", 100, UIFontWeightBold) }].height) / 100;
	CGFloat s = line / ratio;
	RLLog(@"native lyrics: %lu layers, line height %.1f -> font %.1f, margin %.1f", (unsigned long)rects.count, line, s, minX);
	if (s < 16 || s > 48) return NO;
	*size = s;
	*margin = minX >= 8 && minX <= 60 ? minX : 24;
	return YES;
}

static RLLyricsView *gCache;

+ (instancetype)attachTo:(UIScrollView *)tidal {
	RLLyricsView *v = gCache ?: [[self alloc] initWithFrame:tidal.frame];
	gCache = v;
	CGFloat size = 0, margin = 0;
	if (!v->_measured && RLMeasureNative(tidal, &size, &margin)) {
		v->_measured = YES;
		v->_nativeSize = size;
		v->_nativeMargin = margin;
		v->_builtSize = CGSizeZero;
	}
	if (!v->_nativeSize) v->_nativeSize = 28, v->_nativeMargin = 24;
	v->_focus = -2;
	v->_lastUserScroll = 0;
	v.transform = CGAffineTransformIdentity;
	v.frame = tidal.frame;
	v->_tidal = tidal;
	v->_tidalAlpha = tidal.alpha > 0.01 ? tidal.alpha : 1;
	v->_insets = tidal.adjustedContentInset;
	[tidal.superview insertSubview:v aboveSubview:tidal];
	tidal.alpha = 0;
	[v reload];
	return v;
}

- (void)detach {
	self.tidal.alpha = _tidalAlpha;
	[_link invalidate];
	_link = nil;
	[self removeFromSuperview];
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_lineViews = [NSMutableArray array];
		_activeSet = [NSMutableIndexSet indexSet];
		_focus = -2;
		_scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
		_scroll.delegate = self;
		_scroll.showsVerticalScrollIndicator = NO;
		_scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
		[_scroll addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapLyrics:)]];
		[self addSubview:_scroll];
		_fade = [CAGradientLayer layer];
		_fade.colors = @[ (id)UIColor.clearColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor ];
		self.layer.mask = _fade;
	}
	return self;
}

- (void)dealloc { [_link invalidate]; }

- (void)didMoveToWindow {
	[super didMoveToWindow];
	[_link invalidate];
	_link = nil;
	if (!self.window) return;
	RLDisplayProxy *proxy = [RLDisplayProxy new];
	proxy.target = self;
	_link = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
	_link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (CGFloat)anchorY {
	UIWindow *w = self.window;
	CGFloat headerBottom = (w ? w.safeAreaInsets.top : 47) + 184 - (w ? [self convertPoint:CGPointZero toView:nil].y : 0);
	return MAX(40, MIN(MAX(_insets.top, headerBottom), self.bounds.size.height * 0.5));
}

- (void)layoutSubviews {
	[super layoutSubviews];
	_scroll.frame = self.bounds;
	CGFloat a = [self anchorY];
	BOOL moved = fabs(a - _anchor) > 1;
	if (moved) _anchor = a;
	CGFloat h = MAX(1, self.bounds.size.height);
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_fade.frame = self.bounds;
	_fade.locations = @[ @0, @(MIN(0.45, (_insets.top + 36) / h)), @(MAX(0.55, 1 - (_insets.bottom + 60) / h)), @1 ];
	[CATransaction commit];
	// only width changes the line wrapping; TIDAL animates height and position every frame while
	// the cover resizes, and rebuilding every line for that dropped frames
	if (self.bounds.size.width != _builtSize.width) [self rebuild];
	else if (moved || self.bounds.size.height != _builtSize.height) {
		_builtSize = self.bounds.size;
		[self relayout];
		if (_focus >= 0 && !_dragging && _lastUserScroll == 0) [self scrollToFocus:NO bounce:NO];
	}
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	UIView *hit = [super hitTest:point withEvent:event];
	if (!hit || _scroll.isDecelerating) return hit;
	CGPoint p = [self convertPoint:point toView:_scroll];
	for (RLLineView *lv in _lineViews)
		if (CGRectContainsPoint(CGRectInset(lv.frame, -8, -12), p)) return hit;
	return nil;
}

- (void)reload {
	if (RLStore.shared.lines == _lines) return;
	_lines = RLStore.shared.lines;
	[self rebuild];
}

- (void)rebuild {
	for (UIView *v in _lineViews) [v removeFromSuperview];
	[_lineViews removeAllObjects];
	[_activeSet removeAllIndexes];
	_focus = -2;
	_builtSize = self.bounds.size;
	if (!_lines.count || _builtSize.width <= 0) { _scroll.contentSize = CGSizeZero; return; }

	CGFloat size = _nativeSize * RLNum(@"fontScale", 1.14), margin = _nativeMargin, width = _builtSize.width - 2 * margin;
	_gap = _nativeSize * 1.145;
	for (RLLine *line in _lines) {
		RLLineView *lv = [[RLLineView alloc] initWithLine:line width:width size:size];
		lv.layer.position = CGPointMake(line.right ? margin + width : margin, 0);
		[_scroll addSubview:lv];
		[_lineViews addObject:lv];
	}
	[self relayout];
	[self tick];
}

- (void)restart {
	_dragging = NO;
	_lastUserScroll = 0;
	[self rebuild];
}

- (void)relayout {
	CGFloat y = _anchor;
	for (RLLineView *lv in _lineViews) {
		lv.top = y;
		lv.bounds = CGRectMake(0, 0, lv.bounds.size.width, lv.height);
		lv.layer.position = CGPointMake(lv.layer.position.x, y + lv.height / 2);
		y += lv.height + _gap;
	}
	_scroll.contentSize = CGSizeMake(_builtSize.width, MAX(_builtSize.height, y + _insets.bottom + 120));
}

- (void)scrollToFocus:(BOOL)animated bounce:(BOOL)bounce {
	CGFloat h = _scroll.bounds.size.height;
	RLLineView *lv = _focus >= 0 ? _lineViews[_focus] : nil;
	CGFloat y = lv ? lv.top + lv.height / 2 - h * 0.4 : 0;
	y = MAX(0, MIN(y, _scroll.contentSize.height - h));
	if (!animated) { _scroll.contentOffset = CGPointMake(0, y); return; }
	if (bounce) { [self bounceTo:y]; return; }
	[UIView animateWithDuration:0.8 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
	                    options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
	                 animations:^{ self->_scroll.contentOffset = CGPointMake(0, y); } completion:nil];
}

- (void)bounceTo:(CGFloat)y {
	CGFloat cur = (_scroll.layer.presentationLayer ?: _scroll.layer).bounds.origin.y, delta = y - cur, h = _scroll.bounds.size.height;
	[_scroll.layer removeAllAnimations];
	[UIView performWithoutAnimation:^{ self->_scroll.contentOffset = CGPointMake(0, y); }];
	if (fabs(delta) < 2) return;
	static NSUInteger n;
	NSString *key = [NSString stringWithFormat:@"bounce%lu", (unsigned long)++n];
	CAMediaTimingFunction *curve = [CAMediaTimingFunction functionWithControlPoints:0.41 :0 :0.12 :0.99];
	CFTimeInterval now = CACurrentMediaTime();
	CGFloat top = MIN(cur, y) - 60, bottom = MAX(cur, y) + h + 60;
	for (NSInteger i = 0; i < (NSInteger)_lineViews.count; i++) {
		RLLineView *lv = _lineViews[i];
		if (lv.top + lv.height < top || lv.top > bottom) continue;
		CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.y"];
		a.additive = YES;
		a.fromValue = @(delta);
		a.toValue = @0;
		a.duration = 0.4;
		a.beginTime = now + MAX(0, i - _focus) * 0.03;
		a.fillMode = kCAFillModeBackwards;
		a.timingFunction = curve;
		[lv.layer addAnimation:a forKey:key];
	}
}

- (BOOL)followTidal {
	UIScrollView *t = self.tidal;
	if (!t || t.superview != self.superview) return NO;
	if (!CGSizeEqualToSize(self.bounds.size, t.bounds.size)) self.bounds = (CGRect){ CGPointZero, t.bounds.size };
	if (!CGPointEqualToPoint(self.center, t.center)) self.center = t.center;
	if (!CGAffineTransformEqualToTransform(self.transform, t.transform)) self.transform = t.transform;
	if (t.alpha > 0) t.alpha = 0;
	NSArray *subs = self.superview.subviews;
	NSUInteger i = [subs indexOfObjectIdenticalTo:t];
	if (i + 1 >= subs.count || subs[i + 1] != self) [self.superview insertSubview:self aboveSubview:t];
	if (!UIEdgeInsetsEqualToEdgeInsets(t.adjustedContentInset, _insets)) {
		_insets = t.adjustedContentInset;
		if (_focus >= 0) _focus = -3;
	}
	if (fabs([self anchorY] - _anchor) > 1) [self setNeedsLayout];
	return YES;
}

- (void)tick {
	if (![self followTidal]) { [self detach]; return; }
	double t = RLStore.shared.now, now = CACurrentMediaTime();

	NSMutableIndexSet *active = [NSMutableIndexSet indexSet];
	NSInteger last = -1;
	for (NSUInteger i = 0; i < _lineViews.count; i++) {
		RLLine *l = _lineViews[i].line;
		double next = i + 1 < _lineViews.count ? _lineViews[i + 1].line.start : INFINITY;
		if (t >= l.start && t < MAX(l.end, MIN(l.end + 2.5, next))) [active addIndex:i];
		if (t >= l.start) last = i;
	}
	__block BOOL grew = NO, shrank = NO;
	[_activeSet enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
		if ([active containsIndex:i]) return;
		RLLineView *lv = self->_lineViews[i];
		CGFloat before = lv.height;
		lv.active = NO;
		shrank |= lv.height != before;
	}];
	CGFloat glow = RLNum(@"glow", 0.6);
	NSInteger style = (NSInteger)RLNum(@"style", 2);
	[active enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
		RLLineView *lv = self->_lineViews[i];
		CGFloat before = lv.height;
		lv.active = YES;
		grew |= lv.height != before;
		[lv update:t glow:glow style:style];
	}];
	_activeSet = active;

	static const CGFloat kBlurEm[] = { 0, 0.035, 0.05, 0.06, 0.07 };
	BOOL blur = RLBool(@"blurInactive", YES) && !_dragging && _lastUserScroll == 0 && last >= 0;
	NSInteger from = active.count ? (NSInteger)active.firstIndex : last;
	for (NSUInteger i = 0; i < _lineViews.count; i++) {
		NSInteger d = [active containsIndex:i] || (NSInteger)i == from ? 0 : active.count ? MIN(4, labs((NSInteger)i - from)) : 4;
		[_lineViews[i] setBlurEm:blur ? kBlurEm[d] : 0];
	}
	if (grew || shrank) {
		RLEase(grew ? 0.5 : 0.3, ^{ [self relayout]; });
		if (_focus >= 0 && !_dragging && _lastUserScroll == 0) [self scrollToFocus:YES bounce:NO];
	}

	CGFloat y = _scroll.contentOffset.y, h = _scroll.bounds.size.height;
	for (RLLineView *lv in _lineViews) [lv setDrawn:lv.top + lv.height >= y - h && lv.top <= y + 2 * h];

	NSInteger focus = active.count ? (NSInteger)active.firstIndex : last;
	if (_lastUserScroll > 0 && !_dragging && now - _lastUserScroll > 3) { _lastUserScroll = 0; _focus = -3; }
	if (focus != _focus && !_dragging && _lastUserScroll == 0) {
		BOOL animated = _focus != -2;
		BOOL next = RLBool(@"bounce", YES) && _focus >= 0 && focus > _focus && focus - _focus <= 2 && active.count <= 1;
		_focus = focus;
		[self scrollToFocus:animated bounce:next];
	}
}

- (void)tapLyrics:(UITapGestureRecognizer *)g {
	CGPoint p = [g locationInView:_scroll];
	for (RLLineView *lv in _lineViews)
		if (CGRectContainsPoint(CGRectInset(lv.frame, -8, -12), p)) {
			[RLStore.shared seek:lv.line.start + 0.01];
			_lastUserScroll = 0;
			_focus = -3;
			return;
		}
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)s { _dragging = YES; }
- (void)scrollViewDidEndDragging:(UIScrollView *)s willDecelerate:(BOOL)d {
	_dragging = NO;
	_lastUserScroll = CACurrentMediaTime();
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)s { _lastUserScroll = CACurrentMediaTime(); }
@end

void RLOpenSettings(UIViewController *from) {
	while (from.presentedViewController) from = from.presentedViewController;
	if ([from isKindOfClass:RLSettingsViewController.class]) return;
	RLSettingsViewController *s = [RLSettingsViewController new];
	s.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
	s.sheetPresentationController.prefersGrabberVisible = YES;
	[from presentViewController:s animated:YES completion:nil];
}
