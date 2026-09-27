#import <UIKit/UIKit.h>

#define RLLog(fmt, ...) RLLogLine([NSString stringWithFormat:fmt, ##__VA_ARGS__])
void RLLogLine(NSString *line);
NSArray<NSString *> *RLLogLines(void);

#define RLDefaults [NSUserDefaults standardUserDefaults]
static inline BOOL RLBool(NSString *k, BOOL d) { id v = [RLDefaults objectForKey:[@"rl." stringByAppendingString:k]]; return v ? [v boolValue] : d; }
static inline double RLNum(NSString *k, double d) { id v = [RLDefaults objectForKey:[@"rl." stringByAppendingString:k]]; return v ? [v doubleValue] : d; }
static inline void RLSet(NSString *k, id v) { [RLDefaults setObject:v forKey:[@"rl." stringByAppendingString:k]]; }

@interface RLSyl : NSObject
@property (nonatomic, copy) NSString *text; // may end with a space = word boundary
@property (nonatomic) double start, end;
@end

@interface RLLine : NSObject
@property (nonatomic) double start, end;
@property (nonatomic, copy) NSArray<RLSyl *> *main, *bg;
@property (nonatomic, copy) NSArray<RLSyl *> *tr;
@property (nonatomic) NSMutableDictionary<NSString *, NSArray<RLSyl *> *> *mx;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) BOOL right;
@end

typedef NS_ENUM(NSInteger, RLStatus) { RLStatusIdle, RLStatusLoading, RLStatusOK, RLStatusMissing };

NSArray<RLLine *> *RLParse(NSDictionary *json, BOOL romanize);
NSInteger RLGet(NSString *url, NSDictionary *headers, NSTimeInterval timeout, NSData **out);
NSString *RLEnc(NSString *s);
NSString *RLLineKey(NSString *s);
NSArray<RLSyl *> *RLWords(NSString *text, double t);
void RLTranslate(NSArray<RLLine *> *lines, NSString *title, NSString *artist, NSString *lang, void (^done)(BOOL found));

#define kRLTrLangs (@[ @"ko", @"en", @"ja", @"zh", @"es", @"fr", @"de", @"pt", @"it", @"ru", @"vi", @"th", @"id", @"tr", @"tl", @"nl", @"pl", @"ar", @"hi" ])

static inline NSString *RLTrLang(void) {
	NSString *l = [RLDefaults stringForKey:@"rl.trLang"] ?: [NSLocale.preferredLanguages.firstObject substringToIndex:MIN(2, NSLocale.preferredLanguages.firstObject.length)];
	return [kRLTrLangs containsObject:l] ? l : @"en";
}

static inline NSArray<RLSyl *> *RLTrFor(RLLine *l) {
	if (!RLBool(@"tr", NO)) return nil;
	NSString *lang = RLTrLang();
	return [lang isEqualToString:@"en"] ? l.tr : l.mx[lang];
}
void RLFetch(NSString *title, NSString *artist, NSString *isrc, BOOL flush, void (^done)(NSArray<RLLine *> *lines));

@interface RLStore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray<RLLine *> *lines;
@property (nonatomic, readonly) RLStatus status;
@property (nonatomic, readonly) UIImage *artwork;
@property (nonatomic, readonly) BOOL playing;
- (double)now;
- (void)refetch;
- (void)refetch:(BOOL)flush;
- (void)translate;
- (void)seek:(double)t;
@end

@interface RLLyricsView : UIView
@property (nonatomic, weak, readonly) UIScrollView *tidal;
+ (instancetype)attachTo:(UIScrollView *)tidal;
- (void)detach;
- (void)reload;
- (void)rebuild;
- (void)restart;
@end

@interface RLBackdrop : UIView
@property (nonatomic, weak) UIView *follow;
@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, readonly) BOOL hasFrame;
- (void)setCover:(UIImage *)cover;
- (void)tick;
- (void)restart;
@end

void RLOpenSettings(UIViewController *from);
void RLSettingsChanged(NSString *key);
void RLClearCache(void);
void RLReplay(void);

static inline NSString *RLL(NSString *en, NSString *ko) {
	NSInteger lang = (NSInteger)RLNum(@"lang", 0);
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}
