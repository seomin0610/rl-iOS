#import "RL.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

// kRLKawarpMSL is ported from kawarp (MIT, Copyright (c) 2026 Better Lyrics): see THIRD-PARTY.md
#define RLMSL(...) #__VA_ARGS__
static const char *kRLKawarpMSL = "#include <metal_stdlib>\nusing namespace metal;\n" RLMSL(
struct U { float2 res; float time; float blend; float warp; float sat; float dither; float scale; float bright; float contrast; };
struct V { float4 pos [[position]]; };

vertex V rl_vtx(uint id [[vertex_id]]) {
	float2 p = float2(float((id << 1) & 2), float(id & 2));
	V v;
	v.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
	return v;
}

float3 m289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 m289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 permute(float3 x) { return m289_3(((x * 34.0) + 1.0) * x); }

float snoise(float2 v) {
	float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
	float2 i = floor(v + dot(v, C.yy));
	float2 x0 = v - i + dot(i, C.xx);
	float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
	float4 x12 = x0.xyxy + C.xxzz;
	x12.xy -= i1;
	i = m289_2(i);
	float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
	float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), float3(0.0));
	m = m * m;
	m = m * m;
	float3 x = 2.0 * fract(p * C.www) - 1.0;
	float3 h = abs(x) - 0.5;
	float3 ox = floor(x + 0.5);
	float3 a0 = x - ox;
	m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
	float3 g;
	g.x = a0.x * x0.x + h.x * x0.y;
	g.yz = a0.yz * x12.xz + h.yz * x12.yw;
	return 130.0 * dot(m, g);
}

float hash13(float3 seed) {
	float3 q = fract(seed * 0.1031);
	q += dot(q, q.zyx + 31.32);
	return fract((q.x + q.y) * q.z);
}

fragment half4 rl_frag(V vin [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> texA [[texture(0)]], texture2d<float> texB [[texture(1)]], sampler s [[sampler(0)]]) {
	float2 uv0 = vin.pos.xy / u.res;
	float2 uv = clamp((uv0 - 0.5) / u.scale + 0.5, float2(0.0), float2(1.0));
	float t = u.time * 0.05;
	float2 c = uv - 0.5;
	float centerWeight = 1.0 - smoothstep(0.0, 0.7, length(c));
	float n1 = snoise(uv * 0.35 + float2(t, t * 0.7));
	float n2 = snoise(uv * 0.35 + float2(-t * 0.8, t * 0.5) + float2(50.0, 50.0));
	float n3 = snoise(uv * 0.9 + float2(t * 1.2, -t) + float2(100.0, 0.0));
	float n4 = snoise(uv * 0.9 + float2(-t, t * 1.1) + float2(0.0, 100.0));
	float2 warp = float2(n1 * 0.65 + n3 * 0.35, n2 * 0.65 + n4 * 0.35) * centerWeight;
	float2 wuv = clamp(uv + warp * u.warp, float2(0.0), float2(1.0));
	float3 col = mix(texA.sample(s, wuv).rgb, texB.sample(s, wuv).rgb, float3(u.blend));
	float2 c2 = uv0 - 0.5;
	col *= 1.0 - dot(c2, c2) * 0.3;
	float gray = dot(col, float3(0.299, 0.587, 0.114));
	col = mix(float3(gray), col, float3(u.sat));
	float n = hash13(float3(floor(uv0 * u.res), floor(u.time * 60.0)));
	col += (n - 0.5) * u.dither;
	col = (col - 0.5) * u.contrast + 0.5;
	col *= u.bright;
	return half4(half3(saturate(col)), 1.0h);
}
);

typedef struct { float res[2]; float time, blend, warp, sat, dither, scale, bright, contrast; } RLUniforms;

@interface RLBackdropTick : NSObject
@property (nonatomic, weak) RLBackdrop *target;
@end

static const int kN = 128;

static void RLKawase(const float *src, float *dst, int k) {
	int o[4] = { -(k + 1), -k, k, k + 1 };
	for (int y = 0; y < kN; y++)
		for (int x = 0; x < kN; x++) {
			float r = 0, g = 0, b = 0;
			for (int i = 0; i < 4; i++) {
				int yy = MIN(MAX(y + o[i], 0), kN - 1);
				for (int j = 0; j < 4; j++) {
					int xx = MIN(MAX(x + o[j], 0), kN - 1);
					const float *p = src + (yy * kN + xx) * 3;
					r += p[0], g += p[1], b += p[2];
				}
			}
			float *d = dst + (y * kN + x) * 3;
			d[0] = r / 16, d[1] = g / 16, d[2] = b / 16;
		}
}

@implementation RLBackdropTick
- (void)tick { [_target tick]; }
@end

@implementation RLBackdrop {
	id<MTLDevice> _device;
	id<MTLCommandQueue> _queue;
	id<MTLRenderPipelineState> _pipeline;
	id<MTLSamplerState> _sampler;
	id<MTLTexture> _texA, _texB;
	float _prevDarken, _nextDarken, _time, _speedFactor;
	double _transitionStart, _lastFrame;
	CADisplayLink *_link;
	UIImage *_cover;
	NSUInteger _coverToken;
	BOOL _dirty, _locked;
}

+ (Class)layerClass { return CAMetalLayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.userInteractionEnabled = NO;
		self.backgroundColor = UIColor.blackColor;
		_prevDarken = _nextDarken = _speedFactor = 1;
		_device = MTLCreateSystemDefaultDevice();
		CAMetalLayer *layer = (CAMetalLayer *)self.layer;
		layer.device = _device;
		layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		layer.framebufferOnly = YES;
		layer.opaque = YES;
		NSError *err;
		id<MTLLibrary> lib = [_device newLibraryWithSource:@(kRLKawarpMSL) options:nil error:&err];
		MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = [lib newFunctionWithName:@"rl_vtx"];
		d.fragmentFunction = [lib newFunctionWithName:@"rl_frag"];
		d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		_pipeline = lib ? [_device newRenderPipelineStateWithDescriptor:d error:&err] : nil;
		if (!_pipeline) RLLog(@"backdrop shader failed: %@", err.localizedDescription);
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
		sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
		sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
		_sampler = [_device newSamplerStateWithDescriptor:sd];
		_queue = [_device newCommandQueue];
	}
	return self;
}

- (BOOL)ready { return _pipeline != nil; }

- (void)layoutSubviews {
	[super layoutSubviews];
	((CAMetalLayer *)self.layer).drawableSize = self.bounds.size;
	_dirty = YES;
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	[_link invalidate];
	_link = nil;
	if (!self.window) return;
	_lastFrame = 0;
	RLBackdropTick *t = [RLBackdropTick new];
	t.target = self;
	_link = [CADisplayLink displayLinkWithTarget:t selector:@selector(tick)];
	_link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)dealloc { [_link invalidate]; }

static float RLDarkenFor(float luminance) {
	float effective = luminance * 0.75, ceiling = 0.9 - 0.8 * (0.9 - 0.15);
	return effective > ceiling && effective > 0 ? MAX(ceiling / effective, 0.15) : 1;
}

- (void)setCover:(UIImage *)cover {
	if (!cover || cover == _cover || !_pipeline) return;
	_cover = cover;
	NSUInteger token = ++_coverToken;
	int passes = 6;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		uint8_t *px = calloc(kN * kN * 4, 1);
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(px, kN, kN, 8, kN * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
		CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
		CGContextDrawImage(ctx, CGRectMake(0, 0, kN, kN), cover.CGImage);
		CGContextRelease(ctx);
		CGColorSpaceRelease(cs);

		float *a = malloc(sizeof(float) * kN * kN * 3), *b = malloc(sizeof(float) * kN * kN * 3);
		double lum = 0;
		for (int i = 0; i < kN * kN; i++) {
			float r = px[i * 4] / 255.f, g = px[i * 4 + 1] / 255.f, bl = px[i * 4 + 2] / 255.f;
			lum += 0.2126 * r + 0.7152 * g + 0.0722 * bl;
			float s = MIN(MAX((0.299f * r + 0.587f * g + 0.114f * bl) * 2, 0), 1);
			float t = (1 - s * s * (3 - 2 * s)) * 0.15f;
			a[i * 3] = r + (0.157f - r) * t, a[i * 3 + 1] = g + (0.157f - g) * t, a[i * 3 + 2] = bl + (0.235f - bl) * t;
		}
		for (int p = 0; p < passes; p++) {
			RLKawase(a, b, p);
			float *tmp = a; a = b; b = tmp;
		}
		for (int i = 0; i < kN * kN; i++) {
			for (int ch = 0; ch < 3; ch++) px[i * 4 + ch] = (uint8_t)lroundf(MIN(MAX(a[i * 3 + ch], 0), 1) * 255);
			px[i * 4 + 3] = 255;
		}
		float darken = RLDarkenFor(lum / (kN * kN)), c[3] = { 0 };
		int n = kN * kN / 3;
		for (int i = kN * kN - n; i < kN * kN; i++)
			for (int ch = 0; ch < 3; ch++) c[ch] += a[i * 3 + ch] * 0.94f / n;
		float gray = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2];
		for (int ch = 0; ch < 3; ch++) c[ch] = MIN(MAX(((gray + (c[ch] - gray) * 1.25f - 0.5f) * 1.25f + 0.5f) * 0.75f * darken, 0), 1);
		UIColor *avg = [UIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:1];
		free(a);
		free(b);
		dispatch_async(dispatch_get_main_queue(), ^{
			if (token == self->_coverToken) {
				MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:kN height:kN mipmapped:NO];
				id<MTLTexture> tex = [self->_device newTextureWithDescriptor:td];
				[tex replaceRegion:MTLRegionMake2D(0, 0, kN, kN) mipmapLevel:0 withBytes:px bytesPerRow:kN * 4];
				self->_texA = self->_texB ?: tex;
				self->_texB = tex;
				self->_prevDarken = self->_nextDarken;
				self->_nextDarken = darken;
				self->_avgColor = avg;
				self->_transitionStart = CACurrentMediaTime();
			}
			free(px);
		});
	});
}

- (void)tick {
	UIView *f = self.follow;
	if (f) {
		CGFloat ext = f.window.safeAreaInsets.top;
		CGSize size = CGSizeMake(f.bounds.size.width, f.bounds.size.height + ext);
		if (!CGSizeEqualToSize(self.bounds.size, size)) {
			self.bounds = (CGRect){ CGPointZero, size };
			((CAMetalLayer *)self.layer).drawableSize = size; // don't wait for layoutSubviews on the first frame
			_dirty = YES;
		}
		self.center = CGPointMake(f.center.x, f.center.y - ext / 2);
		self.transform = f.transform;
		self.alpha = f.alpha;
	}

	if (!_texB || !_pipeline) return;
	double now = CACurrentMediaTime();
	float dt = _lastFrame ? MIN(now - _lastFrame, 0.1) : 0;
	_lastFrame = now;
	float target = RLStore.shared.playing && RLBool(@"motion", YES) ? 1 : 0, step = dt / 1.8f;
	_speedFactor = _speedFactor < target ? MIN(target, _speedFactor + step) : MAX(target, _speedFactor - step);
	float prev = _time;
	// after a replay the warp follows the song position, not the frame clock, so every take is identical
	_time = _locked ? (target ? (float)MAX(0, [RLStore.shared now]) * 1.75f : _time) : _time + dt * 1.75f * _speedFactor;
	float blend = MIN(1, (now - _transitionStart) / 1.0);
	if ((_locked ? _time == prev : _speedFactor == 0) && blend >= 1 && !_dirty) return;
	_dirty = NO;

	CAMetalLayer *layer = (CAMetalLayer *)self.layer;
	if (layer.drawableSize.width < 1) return;
	id<CAMetalDrawable> drawable = [layer nextDrawable];
	if (!drawable) return;
	RLUniforms u = { { (float)layer.drawableSize.width, (float)layer.drawableSize.height }, _time, blend,
	                 1.0f, 1.25f, 0.015f, 1.0f, 0.75f * (_prevDarken + (_nextDarken - _prevDarken) * blend), 1.25f };
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = drawable.texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
	[enc setRenderPipelineState:_pipeline];
	[enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
	[enc setFragmentTexture:_texA atIndex:0];
	[enc setFragmentTexture:_texB atIndex:1];
	[enc setFragmentSamplerState:_sampler atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[enc endEncoding];
	[cb presentDrawable:drawable];
	[cb commit];
	_hasFrame = YES;
}

- (void)restart {
	_locked = YES;
	_time = 0;
	_texA = _texB;
	_prevDarken = _nextDarken;
	_transitionStart = 0;
	_dirty = YES;
}
@end
