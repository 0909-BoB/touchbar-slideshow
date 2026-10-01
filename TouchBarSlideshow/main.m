// 圖片幻燈片播放器（支援 Touch Bar）
//
// 用法:
//   open Slideshow.app                         每次開啟都會跳出視窗選資料夾和每張秒數（記住上次的選擇）
//   open Slideshow.app --args <資料夾> [-i 秒數] [-r] [-s] [-f]   參數會當成視窗裡的預設值
//
// 視窗:     只顯示圖片。小視窗置頂在右下角，拖曳圖片移動、拉邊緣縮放、雙擊全螢幕
// Touch Bar: ◀ ⏯ ▶ / 秒數 −+ / 🔀 隨機 / 📌 置頂 / ⛶ 全螢幕 / 張數 / 縮圖列（點縮圖跳過去）
// 鍵盤:     空白鍵 暫停、←→↑↓ 切換、+/- 調速度、F 全螢幕、S 隨機、T 置頂、Esc/Q 離開

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>

static const NSSize kThumbSize = {40, 30};

static NSTouchBarItemIdentifier const kPrev = @"slideshow.prev";
static NSTouchBarItemIdentifier const kPlay = @"slideshow.play";
static NSTouchBarItemIdentifier const kNext = @"slideshow.next";
static NSTouchBarItemIdentifier const kSpeed = @"slideshow.speed";
static NSTouchBarItemIdentifier const kShuffle = @"slideshow.shuffle";
static NSTouchBarItemIdentifier const kOnTop = @"slideshow.ontop";
static NSTouchBarItemIdentifier const kFullscreen = @"slideshow.fullscreen";
static NSTouchBarItemIdentifier const kCounter = @"slideshow.counter";
static NSTouchBarItemIdentifier const kStrip = @"slideshow.strip";

static NSArray<NSURL *> *FindImages(NSURL *folder, BOOL recursive) {
    NSSet *exts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"bmp", @"webp", @"tif", @"tiff", @"heic"]];
    NSDirectoryEnumerationOptions opts = NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants;
    if (!recursive) opts |= NSDirectoryEnumerationSkipsSubdirectoryDescendants;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:folder includingPropertiesForKeys:nil options:opts errorHandler:nil];
    NSMutableArray *result = [NSMutableArray array];
    for (NSURL *url in e) {
        if ([exts containsObject:url.pathExtension.lowercaseString]) [result addObject:url];
    }
    [result sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.path localizedStandardCompare:b.path];
    }];
    return result;
}

/// 縮小讀取圖片（依 EXIF 方向轉正），大圖也很快。呼叫者負責 CGImageRelease
static CGImageRef LoadImage(NSURL *url, CGFloat maxPixel) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel),
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    return img;
}

/// Touch Bar 縮圖：裁成 4:3 置中
static NSImage *MakeThumbnail(NSURL *url) {
    CGImageRef cg = LoadImage(url, 160);
    if (!cg) return nil;
    CGFloat w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CGFloat ratio = kThumbSize.width / kThumbSize.height;
    CGRect crop = (w / h > ratio)
        ? CGRectMake((w - h * ratio) / 2, 0, h * ratio, h)
        : CGRectMake(0, (h - w / ratio) / 2, w, w / ratio);
    CGImageRef cropped = CGImageCreateWithImageInRect(cg, CGRectIntegral(crop));
    CGImageRelease(cg);
    if (!cropped) return nil;
    NSImage *img = [[NSImage alloc] initWithCGImage:cropped size:kThumbSize];
    CGImageRelease(cropped);
    return img;
}

static NSImage *Symbol(NSString *name) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
}

@class SlideshowController;

@interface SlideWindow : NSWindow
@property (weak) SlideshowController *controller;
@end

@interface SlideshowController : NSObject <NSWindowDelegate, NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate>
- (instancetype)initWithImages:(NSArray<NSURL *> *)images interval:(NSTimeInterval)interval shuffle:(BOOL)shuffle fullscreen:(BOOL)fullscreen;
- (BOOL)handleKey:(NSEvent *)event;
@end

@implementation SlideWindow
- (void)keyDown:(NSEvent *)event {
    if (![self.controller handleKey:event]) [super keyDown:event];
}
@end

/// 拖曳圖片移動視窗，雙擊切換全螢幕
@interface DragImageView : NSImageView
@end

@implementation DragImageView
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) [self.window toggleFullScreen:nil];
    else [self.window performWindowDragWithEvent:event];
}
@end

@implementation SlideshowController {
    SlideWindow *_window;
    NSImageView *_imageView;

    NSArray<NSURL *> *_original;
    NSArray<NSURL *> *_images;
    NSInteger _index;
    NSTimeInterval _interval;
    BOOL _paused;
    BOOL _shuffle;
    NSTimer *_timer;
    NSInteger _loadToken;
    dispatch_queue_t _imageQueue;

    // Touch Bar
    NSScrubber *_scrubber;
    NSTextField *_counter;
    NSButton *_playButton;
    NSButton *_shuffleButton;
    NSButton *_onTopButton;
    NSButton *_fullscreenButton;
    NSStepperTouchBarItem *_speedItem;
    BOOL _syncingScrubber;
    NSCache<NSURL *, NSImage *> *_thumbCache;
    NSMutableSet<NSURL *> *_thumbLoading;
    NSOperationQueue *_thumbQueue;
    NSImage *_placeholder;
}

static NSArray *Shuffled(NSArray *a) {
    NSMutableArray *m = [a mutableCopy];
    for (NSUInteger i = m.count; i > 1; i--) [m exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    return m;
}

- (instancetype)initWithImages:(NSArray<NSURL *> *)images interval:(NSTimeInterval)interval shuffle:(BOOL)shuffle fullscreen:(BOOL)fullscreen {
    if (!(self = [super init])) return nil;
    _original = images;
    _images = shuffle ? Shuffled(images) : images;
    _interval = interval;
    _shuffle = shuffle;
    _imageQueue = dispatch_queue_create("slideshow.image", DISPATCH_QUEUE_SERIAL);
    _thumbCache = [NSCache new];
    _thumbLoading = [NSMutableSet set];
    _thumbQueue = [NSOperationQueue new];
    _thumbQueue.maxConcurrentOperationCount = 4;
    _thumbQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    _placeholder = [NSImage imageWithSize:kThumbSize flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.darkGrayColor setFill];
        NSRectFill(r);
        return YES;
    }];

    // 小視窗：無標題列、置頂、預設在螢幕右下角
    _window = [[SlideWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 270)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                       | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                                               backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed = NO;
    _window.controller = self;
    _window.delegate = self;
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _window.backgroundColor = NSColor.blackColor;
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    _window.level = NSFloatingWindowLevel;
    _window.minSize = NSMakeSize(160, 120);
    NSRect visible = (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
    [_window setFrameOrigin:NSMakePoint(NSMaxX(visible) - 360 - 20, NSMinY(visible) + 20)];
    [_window setFrameAutosaveName:@"SlideshowMini"];  // 記住上次的位置和大小

    // 視窗只放圖片，關閉/縮小/放大按鈕也藏起來
    for (NSNumber *b in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        [_window standardWindowButton:b.integerValue].hidden = YES;
    }
    NSView *content = _window.contentView;
    _imageView = [[DragImageView alloc] initWithFrame:content.bounds];
    _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_imageView];

    [self setupScrubber];
    _window.touchBar = [self makeTouchBar];

    [_window makeKeyAndOrderFront:nil];
    if (fullscreen) [_window toggleFullScreen:nil];
    [self show];
    [self schedule];
    return self;
}

#pragma mark 顯示

- (void)show {
    NSURL *url = _images[_index];
    NSInteger token = ++_loadToken;
    NSScreen *screen = _window.screen ?: NSScreen.mainScreen;
    CGFloat maxPixel = MAX(screen.frame.size.width, screen.frame.size.height) * screen.backingScaleFactor;
    dispatch_async(_imageQueue, ^{
        CGImageRef cg = LoadImage(url, maxPixel);
        NSImage *img = cg ? [[NSImage alloc] initWithCGImage:cg size:NSZeroSize] : nil;
        if (cg) CGImageRelease(cg);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token == self->_loadToken) self->_imageView.image = img;
        });
    });
    _window.title = [@"幻燈片 - " stringByAppendingString:url.lastPathComponent];  // 給 Mission Control / 視窗選單用
    [self syncTouchBar];
}

- (void)toggleOnTop {
    _window.level = _window.level == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel;
    [self syncTouchBar];
}

- (void)windowDidEnterFullScreen:(NSNotification *)n { [self syncTouchBar]; }
- (void)windowDidExitFullScreen:(NSNotification *)n { [self syncTouchBar]; }

#pragma mark 控制

- (void)schedule {
    [_timer invalidate];
    _timer = nil;
    if (!_paused) {
        __weak typeof(self) weakSelf = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:_interval repeats:NO block:^(NSTimer *t) {
            [weakSelf step:1];
        }];
    }
}

- (void)step:(NSInteger)delta {
    NSInteger n = _images.count;
    _index = ((_index + delta) % n + n) % n;
    [self show];
    [self schedule];
}

- (void)jumpTo:(NSInteger)i {
    if (i == _index || i < 0 || i >= (NSInteger)_images.count) return;
    _index = i;
    [self show];
    [self schedule];
}

- (void)togglePause {
    _paused = !_paused;
    [self syncTouchBar];
    [self schedule];
}

- (void)changeSpeed:(NSTimeInterval)delta {
    _interval = MIN(60, MAX(0.5, _interval + delta));
    [self syncTouchBar];
    [self schedule];
}

- (void)toggleShuffle {
    NSURL *current = _images[_index];
    _shuffle = !_shuffle;
    _images = _shuffle ? Shuffled(_original) : _original;
    NSUInteger i = [_images indexOfObject:current];
    _index = i == NSNotFound ? 0 : i;
    [_scrubber reloadData];
    [self syncTouchBar];
}

- (BOOL)handleKey:(NSEvent *)e {
    switch (e.keyCode) {
        case 49: [self togglePause]; return YES;          // space
        case 124: case 125: [self step:1]; return YES;    // → ↓
        case 123: case 126: [self step:-1]; return YES;   // ← ↑
        case 53:                                          // esc
            if (_window.styleMask & NSWindowStyleMaskFullScreen) [_window toggleFullScreen:nil];
            else [NSApp terminate:nil];
            return YES;
    }
    NSString *c = e.charactersIgnoringModifiers.lowercaseString;
    if ([c isEqualToString:@"+"] || [c isEqualToString:@"="]) [self changeSpeed:-0.5];
    else if ([c isEqualToString:@"-"]) [self changeSpeed:0.5];
    else if ([c isEqualToString:@"f"]) [_window toggleFullScreen:nil];
    else if ([c isEqualToString:@"s"]) [self toggleShuffle];
    else if ([c isEqualToString:@"t"]) [self toggleOnTop];
    else if ([c isEqualToString:@"q"]) [NSApp terminate:nil];
    else return NO;
    return YES;
}

- (void)prevTapped { [self step:-1]; }
- (void)nextTapped { [self step:1]; }
- (void)playTapped { [self togglePause]; }
- (void)shuffleTapped { [self toggleShuffle]; }
- (void)onTopTapped { [self toggleOnTop]; }
- (void)fullscreenTapped { [_window toggleFullScreen:nil]; }

- (void)speedChanged:(NSStepperTouchBarItem *)item {
    _interval = item.value;
    [self schedule];
}

#pragma mark Touch Bar

- (NSTouchBar *)makeTouchBar {
    NSTouchBar *bar = [NSTouchBar new];
    bar.delegate = self;
    bar.defaultItemIdentifiers = @[kPrev, kPlay, kNext, kSpeed, kShuffle, kOnTop, kFullscreen, kCounter, kStrip];
    return bar;
}

/// 窄一點的按鈕，讓縮圖列有空間
- (NSCustomTouchBarItem *)buttonItem:(NSTouchBarItemIdentifier)ident symbol:(NSString *)name action:(SEL)action {
    NSButton *button = [NSButton buttonWithImage:Symbol(name) target:self action:action];
    [button.widthAnchor constraintEqualToConstant:44].active = YES;
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:ident];
    item.view = button;
    return item;
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)ident {
    if ([ident isEqualToString:kPrev]) return [self buttonItem:ident symbol:@"backward.fill" action:@selector(prevTapped)];
    if ([ident isEqualToString:kNext]) return [self buttonItem:ident symbol:@"forward.fill" action:@selector(nextTapped)];
    if ([ident isEqualToString:kPlay]) {
        NSCustomTouchBarItem *item = [self buttonItem:ident symbol:@"pause.fill" action:@selector(playTapped)];
        _playButton = (NSButton *)item.view;
        [self syncTouchBar];
        return item;
    }
    if ([ident isEqualToString:kShuffle]) {
        NSCustomTouchBarItem *item = [self buttonItem:ident symbol:@"shuffle" action:@selector(shuffleTapped)];
        _shuffleButton = (NSButton *)item.view;
        [self syncTouchBar];
        return item;
    }
    if ([ident isEqualToString:kOnTop]) {
        NSCustomTouchBarItem *item = [self buttonItem:ident symbol:@"pin.fill" action:@selector(onTopTapped)];
        _onTopButton = (NSButton *)item.view;
        [self syncTouchBar];
        return item;
    }
    if ([ident isEqualToString:kFullscreen]) {
        NSCustomTouchBarItem *item = [self buttonItem:ident symbol:@"arrow.up.left.and.arrow.down.right" action:@selector(fullscreenTapped)];
        _fullscreenButton = (NSButton *)item.view;
        [self syncTouchBar];
        return item;
    }
    if ([ident isEqualToString:kSpeed]) {
        NSNumberFormatter *fmt = [NSNumberFormatter new];
        fmt.numberStyle = NSNumberFormatterDecimalStyle;
        fmt.minimumFractionDigits = 1;
        fmt.maximumFractionDigits = 1;
        fmt.positiveSuffix = @" 秒";
        _speedItem = [NSStepperTouchBarItem stepperTouchBarItemWithIdentifier:ident formatter:fmt];
        _speedItem.minValue = 0.5;
        _speedItem.maxValue = 60;
        _speedItem.increment = 0.5;
        _speedItem.value = _interval;
        _speedItem.target = self;
        _speedItem.action = @selector(speedChanged:);
        return _speedItem;
    }
    if ([ident isEqualToString:kCounter]) {
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:ident];
        _counter = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld/%lu", (long)_index + 1, (unsigned long)_images.count]];
        _counter.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
        _counter.alignment = NSTextAlignmentCenter;
        item.view = _counter;
        return item;
    }
    if ([ident isEqualToString:kStrip]) {
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:ident];
        item.view = _scrubber;
        return item;
    }
    return nil;
}

- (void)setupScrubber {
    _scrubber = [NSScrubber new];
    [_scrubber registerClass:NSScrubberImageItemView.class forItemIdentifier:@"thumb"];
    _scrubber.dataSource = self;
    _scrubber.delegate = self;
    _scrubber.mode = NSScrubberModeFree;
    _scrubber.selectionOverlayStyle = NSScrubberSelectionStyle.outlineOverlayStyle;
    NSScrubberFlowLayout *layout = [NSScrubberFlowLayout new];
    layout.itemSize = kThumbSize;
    layout.itemSpacing = 2;
    _scrubber.scrubberLayout = layout;
    _scrubber.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *preferred = [_scrubber.widthAnchor constraintEqualToConstant:800];
    preferred.priority = NSLayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[preferred, [_scrubber.widthAnchor constraintGreaterThanOrEqualToConstant:200]]];
}

- (void)syncTouchBar {
    BOOL fullscreen = (_window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    _counter.stringValue = [NSString stringWithFormat:@"%ld/%lu", (long)_index + 1, (unsigned long)_images.count];
    _playButton.image = Symbol(_paused ? @"play.fill" : @"pause.fill");
    _shuffleButton.bezelColor = _shuffle ? NSColor.systemBlueColor : nil;
    _onTopButton.bezelColor = _window.level == NSFloatingWindowLevel ? NSColor.systemBlueColor : nil;
    _fullscreenButton.image = Symbol(fullscreen ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right");
    _speedItem.value = _interval;
    _syncingScrubber = YES;
    _scrubber.selectedIndex = _index;
    [_scrubber.animator scrollItemAtIndex:_index toAlignment:NSScrubberAlignmentCenter];
    _syncingScrubber = NO;
}

- (NSInteger)numberOfItemsForScrubber:(NSScrubber *)scrubber {
    return _images.count;
}

- (NSScrubberItemView *)scrubber:(NSScrubber *)scrubber viewForItemAtIndex:(NSInteger)i {
    NSScrubberImageItemView *view = [scrubber makeItemWithIdentifier:@"thumb" owner:nil];
    view.image = [self thumbnailAt:i] ?: _placeholder;
    return view;
}

- (void)scrubber:(NSScrubber *)scrubber didSelectItemAtIndex:(NSInteger)i {
    if (!_syncingScrubber) [self jumpTo:i];
}

/// 有快取就回傳，沒有就背景產生後更新那一格
- (NSImage *)thumbnailAt:(NSInteger)i {
    NSURL *url = _images[i];
    NSImage *cached = [_thumbCache objectForKey:url];
    if (cached) return cached;
    if ([_thumbLoading containsObject:url]) return nil;
    [_thumbLoading addObject:url];
    [_thumbQueue addOperationWithBlock:^{
        NSImage *img = MakeThumbnail(url) ?: self->_placeholder;
        [NSOperationQueue.mainQueue addOperationWithBlock:^{
            [self->_thumbLoading removeObject:url];
            [self->_thumbCache setObject:img forKey:url];
            if (i < (NSInteger)self->_images.count && [self->_images[i] isEqual:url]) {
                [self->_scrubber reloadItemsAtIndexes:[NSIndexSet indexSetWithIndex:i]];
                if (i == self->_index) self->_scrubber.selectedIndex = i;
            }
        }];
    }];
    return nil;
}

- (void)windowWillClose:(NSNotification *)notification {
    [_timer invalidate];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) SlideshowController *controller;
@end

@implementation AppDelegate {
    NSTextField *_intervalField;
    NSStepper *_intervalStepper;
}

static NSString *const kLastFolderKey = @"lastFolder";
static NSString *const kIntervalKey = @"interval";

/// 開啟時的選擇視窗：資料夾 + 每張秒數。取消回傳 NO
- (BOOL)askFolder:(NSURL **)folder interval:(NSTimeInterval *)interval {
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 44)];
    NSTextField *label = [NSTextField labelWithString:@"每張圖片顯示"];
    NSTextField *unit = [NSTextField labelWithString:@"秒"];

    NSNumberFormatter *fmt = [NSNumberFormatter new];
    fmt.numberStyle = NSNumberFormatterDecimalStyle;
    fmt.minimum = @0.5;
    fmt.maximum = @60;
    fmt.maximumFractionDigits = 1;
    _intervalField = [NSTextField textFieldWithString:@""];
    _intervalField.formatter = fmt;
    _intervalField.alignment = NSTextAlignmentRight;
    _intervalField.doubleValue = *interval;
    _intervalField.target = self;
    _intervalField.action = @selector(intervalFieldChanged:);

    _intervalStepper = [NSStepper new];
    _intervalStepper.minValue = 0.5;
    _intervalStepper.maxValue = 60;
    _intervalStepper.increment = 0.5;
    _intervalStepper.valueWraps = NO;
    _intervalStepper.doubleValue = *interval;
    _intervalStepper.target = self;
    _intervalStepper.action = @selector(intervalStepperChanged:);

    NSStackView *row = [NSStackView stackViewWithViews:@[label, _intervalField, _intervalStepper, unit]];
    row.spacing = 6;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [accessory addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [_intervalField.widthAnchor constraintEqualToConstant:56],
        [row.centerXAnchor constraintEqualToAnchor:accessory.centerXAnchor],
        [row.centerYAnchor constraintEqualToAnchor:accessory.centerYAnchor],
    ]];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.message = @"選擇要播放的圖片資料夾";
    panel.prompt = @"播放";
    panel.accessoryView = accessory;
    panel.accessoryViewDisclosed = YES;
    if (*folder) panel.directoryURL = *folder;
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return NO;

    *folder = panel.URL;
    *interval = MIN(60, MAX(0.5, _intervalField.doubleValue ?: *interval));
    return YES;
}

- (void)intervalFieldChanged:(NSTextField *)sender { _intervalStepper.doubleValue = sender.doubleValue; }
- (void)intervalStepperChanged:(NSStepper *)sender { _intervalField.doubleValue = sender.doubleValue; }

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenu];
    [NSApp activateIgnoringOtherApps:YES];

    // 預設值：上次用的資料夾和秒數，命令列參數可以覆蓋
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *lastFolder = [defaults stringForKey:kLastFolderKey];
    NSURL *folder = lastFolder ? [NSURL fileURLWithPath:lastFolder] : nil;
    NSTimeInterval interval = [defaults doubleForKey:kIntervalKey] ?: 3;
    BOOL recursive = NO, shuffle = NO, fullscreen = NO;
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    for (NSUInteger k = 1; k < args.count; k++) {
        NSString *a = args[k];
        if ([a isEqualToString:@"-i"] || [a isEqualToString:@"--interval"]) {
            if (k + 1 < args.count) interval = args[++k].doubleValue ?: interval;
        } else if ([a isEqualToString:@"-r"] || [a isEqualToString:@"--recursive"]) recursive = YES;
        else if ([a isEqualToString:@"-s"] || [a isEqualToString:@"--shuffle"]) shuffle = YES;
        else if ([a isEqualToString:@"-f"] || [a isEqualToString:@"--fullscreen"]) fullscreen = YES;
        else if ([a hasPrefix:@"-"]) { if ([a hasPrefix:@"-NS"] || [a hasPrefix:@"-Apple"]) k++; }  // 系統參數
        else folder = [NSURL fileURLWithPath:a.stringByExpandingTildeInPath];
    }

    // 每次開啟都先問資料夾和秒數；資料夾沒圖就再問一次
    NSArray *images = nil;
    while (images.count == 0) {
        if (![self askFolder:&folder interval:&interval]) { [NSApp terminate:nil]; return; }
        images = FindImages(folder, recursive);
        if (images.count == 0 && !recursive) images = FindImages(folder, YES);  // 只有子資料夾有圖時自動往下找
        if (images.count == 0) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"資料夾裡沒有圖片";
            alert.informativeText = folder.path;
            [alert runModal];
        }
    }
    [defaults setObject:folder.path forKey:kLastFolderKey];
    [defaults setDouble:interval forKey:kIntervalKey];

    printf("找到 %lu 張圖片，每張 %.1f 秒\n", (unsigned long)images.count, interval);
    fflush(stdout);
    self.controller = [[SlideshowController alloc] initWithImages:images interval:interval shuffle:shuffle fullscreen:fullscreen];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)buildMenu {
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [main addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"結束幻燈片" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = main;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
