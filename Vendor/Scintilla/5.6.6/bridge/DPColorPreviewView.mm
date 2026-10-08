#import "DPColorPreviewView.h"
#import "ScintillaView.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>
#include <vector>

@implementation DPColorPreviewView {
    NSArray<NSDictionary *> *_entries;
    NSArray<NSDictionary *> *_rows;
    BOOL _editable;
    NSColorPanel *_chooser;
    NSDictionary *_chosenEntry;
    uint64_t _revision;
    NSUInteger _inspectedBytes;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { _entries = @[]; _changeColorLabel = @""; _applyLabel = @""; self.accessibilityIdentifier = @"duckpad.editor.colors"; self.accessibilityElement = NO; }
    return self;
}
- (void)setChangeColorLabel:(NSString *)label {
    _changeColorLabel = [label copy]; _rows = nil;
    if (_chooser) _chooser.title = label;
}
- (void)setApplyLabel:(NSString *)label {
    _applyLabel = [label copy]; _rows = nil;
    for (NSView *view in _chooser.accessoryView.subviews)
        if ([view isKindOfClass:NSButton.class]) ((NSButton *)view).title = label;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (void)scrollWheel:(NSEvent *)event { [self.scintilla.scrollView scrollWheel:event]; }
- (NSView *)hitTest:(NSPoint)point {
    // Empty gutter keeps native line-selection and context-menu behavior.
    NSView *hit = [super hitTest:point];
    return hit == self ? nil : hit;
}
- (NSArray<NSValue *> *)ranges { return [_entries valueForKey:@"range"]; }
+ (NSColor *)colorFromHex:(NSData *)hex plantUML:(BOOL)plantUML {
    const unsigned char *bytes = static_cast<const unsigned char *>(hex.bytes);
    if (hex.length < 2 || bytes[0] != '#') return nil;
    const NSUInteger digits = hex.length - 1;
    if (!(digits == 3 || digits == 6 || digits == 8 || (!plantUML && digits == 4) || (plantUML && digits == 1))) return nil;
    unsigned components[4] = {0, 0, 0, 255};
    for (NSUInteger index = 1; index < hex.length; ++index) if (!std::isxdigit(bytes[index])) return nil;
    auto nibble = [](unsigned char c) -> unsigned { return std::isdigit(c) ? c - '0' : std::tolower(c) - 'a' + 10; };
    if (digits == 1) components[0] = components[1] = components[2] = nibble(bytes[1]) * 17;
    else if (digits <= 4) for (NSUInteger index = 0; index < digits; ++index) components[index] = nibble(bytes[index + 1]) * 17;
    else for (NSUInteger index = 0; index < digits / 2; ++index) components[index] = nibble(bytes[1 + index * 2]) * 16 + nibble(bytes[2 + index * 2]);
    return [NSColor colorWithSRGBRed:components[0] / 255.0 green:components[1] / 255.0
                              blue:components[2] / 255.0 alpha:components[3] / 255.0];
}
+ (NSData *)hexFromColor:(NSColor *)color preserving:(NSData *)original plantUML:(BOOL)plantUML {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return original;
    unsigned values[4] = { static_cast<unsigned>(std::lround(rgb.redComponent * 255)),
        static_cast<unsigned>(std::lround(rgb.greenComponent * 255)),
        static_cast<unsigned>(std::lround(rgb.blueComponent * 255)),
        static_cast<unsigned>(std::lround(rgb.alphaComponent * 255)) };
    NSString *old = [[NSString alloc] initWithData:original encoding:NSASCIIStringEncoding];
    const NSUInteger digits = original.length - 1;
    const BOOL alpha = digits == 4 || digits == 8 || values[3] < 255;
    const BOOL shortForm = !(plantUML && alpha) && (digits == 1 || digits == 3 || digits == 4) &&
        values[0] % 17 == 0 && values[1] % 17 == 0 && values[2] % 17 == 0 && (!alpha || values[3] % 17 == 0);
    NSMutableString *hex = [NSMutableString stringWithString:@"#"];
    if (digits == 1 && !alpha && shortForm && values[0] == values[1] && values[1] == values[2]) {
        [hex appendFormat:@"%X", values[0] / 17];
    } else {
        for (NSUInteger index = 0; index < (alpha ? 4 : 3); ++index)
            [hex appendFormat:shortForm ? @"%X" : @"%02X", shortForm ? values[index] / 17 : values[index]];
    }
    if (![old isEqualToString:old.uppercaseString]) hex = [hex.lowercaseString mutableCopy];
    return [hex dataUsingEncoding:NSASCIIStringEncoding];
}
- (NSImage *)imageForColor:(NSColor *)color {
    return [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.whiteColor setFill]; NSRectFill(rect);
        [NSColor.lightGrayColor setFill];
        NSRectFill(NSMakeRect(0, 0, 6, 6)); NSRectFill(NSMakeRect(6, 6, 6, 6));
        [color setFill]; NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
        [NSColor.labelColor setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(rect, 0.5, 0.5)];
        border.lineWidth = 1; [border stroke];
        return YES;
    }];
}
- (void)refreshWithRevision:(uint64_t)revision enabled:(BOOL)enabled editable:(BOOL)editable plantUML:(BOOL)plantUML {
    if (_chooser && (!enabled || !editable || revision != _revision)) [self closeChooser];
    _revision = revision;
    ScintillaView *sci = self.scintilla;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    _inspectedBytes = 0;
    if (enabled && sci && !self.hidden) {
        const NSInteger count = [sci message:SCI_GETLINECOUNT];
        const NSInteger first = [sci message:SCI_GETFIRSTVISIBLELINE];
        const NSInteger screens = MIN(512, [sci message:SCI_LINESONSCREEN] + 2);
        NSInteger previous = -1;
        for (NSInteger visible = first; visible < first + screens; ++visible) {
            const NSInteger line = [sci message:SCI_DOCLINEFROMVISIBLE wParam:visible];
            if (line == previous || line < 0 || line >= count) continue;
            previous = line;
            const NSInteger start = [sci message:SCI_POSITIONFROMLINE wParam:line];
            const NSInteger end = [sci message:SCI_GETLINEENDPOSITION wParam:line];
            const CGFloat y = [sci message:SCI_POINTYFROMPOSITION wParam:0 lParam:start];
            const CGFloat height = [sci message:SCI_TEXTHEIGHT wParam:line];
            if (y + height <= 0 || y >= self.bounds.size.height) continue;
            const NSInteger length = MIN(16384, end - start);
            if (length <= 0 || _inspectedBytes + length > 262144) continue;
            _inspectedBytes += length;
            std::vector<char> bytes(length + 1, '\0');
            Sci_TextRangeFull range = {{start, start + length}, bytes.data()};
            [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:reinterpret_cast<sptr_t>(&range)];
            NSMutableArray *colors = [NSMutableArray array];
            for (NSInteger i = 0; i < length && entries.count < 256; ++i) {
                if (bytes[i] != '#' || (i > 0 && (std::isalnum(static_cast<unsigned char>(bytes[i - 1])) || bytes[i - 1] == '_' || static_cast<unsigned char>(bytes[i - 1]) >= 128))) continue;
                NSInteger next = i + 1;
                while (next < length && std::isxdigit(static_cast<unsigned char>(bytes[next]))) ++next;
                // Do not turn the bounded prefix of a very long token into a color.
                if (next == length && start + length < end) continue;
                if (next < length && (std::isalnum(static_cast<unsigned char>(bytes[next])) || bytes[next] == '_' || static_cast<unsigned char>(bytes[next]) >= 128)) continue;
                NSData *hex = [NSData dataWithBytes:bytes.data() + i length:next - i];
                NSColor *color = [DPColorPreviewView colorFromHex:hex plantUML:plantUML];
                if (!color || (self.shouldPreviewAt && !self.shouldPreviewAt(start + i))) continue;
                NSDictionary *entry = @{@"range": [NSValue valueWithRange:NSMakeRange(start + i, next - i)],
                    @"hex": hex, @"color": color};
                [entries addObject:entry]; [colors addObject:entry]; i = next - 1;
            }
            if (colors.count) [rows addObject:@{@"colors": colors, @"y": @(y + MAX(0, (height - 14) / 2))}];
        }
    }
    _entries = entries;
    if ([_rows isEqualToArray:rows] && _editable == editable) return;
    _rows = rows; _editable = editable;
    // Keep a chooser selection independent of disposable viewport controls.
    for (NSView *view in self.subviews.copy) [view removeFromSuperview];
    NSUInteger rowIndex = 0;
    for (NSDictionary *row in rows) {
        NSArray *colors = row[@"colors"];
        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(1, [row[@"y"] doubleValue], 14, 14)];
        button.bordered = NO; button.imagePosition = NSImageOnly;
        button.image = [self imageForColor:colors[0][@"color"]];
        button.target = self; button.action = @selector(selectColor:); button.enabled = editable;
        button.tag = rowIndex++;
        NSMutableArray *hexes = [NSMutableArray array];
        for (NSDictionary *entry in colors) [hexes addObject:[[NSString alloc] initWithData:entry[@"hex"] encoding:NSASCIIStringEncoding]];
        button.toolTip = [NSString stringWithFormat:@"%@ · %@", self.changeColorLabel ?: @"", [hexes componentsJoinedByString:@", "]];
        button.accessibilityLabel = button.toolTip;
        button.accessibilityIdentifier = @"duckpad.editor.color-chip";
        [self addSubview:button];
    }
}
- (void)selectColor:(NSButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= _rows.count) return;
    NSArray *colors = _rows[sender.tag][@"colors"];
    if (colors.count == 1) { [self showChooser:colors[0]]; return; }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    for (NSDictionary *entry in colors) {
        NSString *hex = [[NSString alloc] initWithData:entry[@"hex"] encoding:NSASCIIStringEncoding];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:hex action:@selector(selectMenuColor:) keyEquivalent:@""];
        item.target = self; item.representedObject = entry; item.image = [self imageForColor:entry[@"color"]];
        [menu addItem:item];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(sender.bounds)) inView:sender];
}
- (void)selectMenuColor:(NSMenuItem *)sender { [self showChooser:sender.representedObject]; }
- (void)showChooser:(NSDictionary *)entry {
    [self closeChooser];
    _chosenEntry = entry;
    _chooser = [[NSColorPanel alloc] initWithContentRect:NSMakeRect(0, 0, 250, 300)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    _chooser.releasedWhenClosed = NO;
    _chooser.title = self.changeColorLabel;
    _chooser.showsAlpha = YES;
    _chooser.color = entry[@"color"];
    NSButton *apply = [NSButton buttonWithTitle:self.applyLabel target:self action:@selector(applyColor:)];
    apply.bezelStyle = NSBezelStyleRounded; apply.keyEquivalent = @"\r";
    apply.frame = NSMakeRect(8, 8, 234, 28);
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 44)];
    [accessory addSubview:apply]; _chooser.accessoryView = accessory;
    [_chooser center]; [_chooser makeKeyAndOrderFront:nil];
}
- (void)applyColor:(id)sender {
    NSColor *color = _chooser.color;
    NSDictionary *entry = _chosenEntry;
    const uint64_t revision = _revision;
    [self closeChooser];
    if (entry && self.onReplaceColor) self.onReplaceColor([entry[@"range"] rangeValue], entry[@"hex"], color, revision);
}
- (void)closeChooser { [_chooser close]; _chooser = nil; _chosenEntry = nil; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; if (!self.window) [self closeChooser]; }
- (void)dealloc { [_chooser close]; }
@end
