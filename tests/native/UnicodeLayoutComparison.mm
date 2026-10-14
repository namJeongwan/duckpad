// Prints deterministic geometry for comparison against the previous release.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "DuckpadScintillaBridge.h"
#import "ScintillaView.h"
#include <iostream>
#include <string>
int main() { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    auto *view = [[DPScintillaEditorView alloc] initWithFrame:NSMakeRect(0,0,900,600)];
    auto *window = [[NSWindow alloc] initWithContentRect:view.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO; window.contentView=view; [window orderFront:nil];
    ScintillaView *sc=nil;
    for(NSView *child in view.subviews) if([child isKindOfClass:ScintillaView.class]) sc=(ScintillaView*)child;
    for(const std::string item : {std::string("a한🦆é 각나\t12\t "), std::string("abcd\tqwerty\t12 "), std::string("a\\b\xc0\xaf\x80z "), std::string("👩‍💻🇰🇷é각 ")}) {
        std::string text; while(text.size()<90000) text+=item;
        [sc message:SCI_SETTEXT wParam:0 lParam:reinterpret_cast<sptr_t>(text.c_str())];
        for(NSString *font in @[@"Menlo",@"Helvetica"]) for(int width : {1,4,8}) for(int wrap : {SC_WRAP_WORD,SC_WRAP_CHAR,SC_WRAP_WHITESPACE}) for(int tabs : {0,1}) {
            [view configureEditorFont:font size:13];
            [sc message:SCI_SETTABWIDTH wParam:width];
            [sc message:SCI_SETTABDRAWMODE wParam:tabs];
            [sc message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
            [sc message:SCI_SETWRAPMODE wParam:wrap];
            [sc message:SCI_SETFIRSTVISIBLELINE wParam:0];
            [view layoutSubtreeIfNeeded];[view displayIfNeeded];[CATransaction flush];
            uint64_t hash=1469598103934665603ULL;
            for(size_t pos : {size_t(0),size_t(1),size_t(300),size_t(4095),text.size()/2,text.size()-1}) {
                for(unsigned int message : {SCI_POINTXFROMPOSITION,SCI_POINTYFROMPOSITION}) { hash^=[sc message:message wParam:0 lParam:pos];hash*=1099511628211ULL; }
                hash^=[sc message:SCI_GETCOLUMN wParam:pos];hash*=1099511628211ULL;
            }
            hash^=[sc message:SCI_WRAPCOUNT wParam:0];
            std::cout << item.size() << ' ' << font.UTF8String << ' ' << width << ' ' << wrap << ' ' << tabs << ' ' << hash << '\n';
        }
    }
    [view invalidate];[window close];
}}
