#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "DuckpadScintillaBridge.h"
#import "ScintillaView.h"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string>
#include "ILexer.h"
#include "Lexilla.h"

static void check(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
static ScintillaView *native(DPScintillaEditorView *view) {
    for (NSView *child in view.subviews) if ([child isKindOfClass:ScintillaView.class]) return (ScintillaView *)child;
    throw std::runtime_error("native view missing");
}
static void draw(NSWindow *window) {
    [window.contentView layoutSubtreeIfNeeded]; [window.contentView displayIfNeeded];
    [CATransaction flush];
}
static void wait(DPScintillaEditorView *view, NSWindow *window) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    do {
        check(std::chrono::steady_clock::now() < deadline, "styling timeout");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        draw(window);
    } while (view.asynchronousWorkPending);
}
int main() { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    try {
        for (NSString *name in @[@"cpp", @"css", @"xml"]) {
            std::string text;
            const std::string item = [name isEqualToString:@"cpp"] ? "function f(x){return x+1;}" :
                [name isEqualToString:@"css"] ? ".item{color:red;padding:4px;}" : "<item id=\"1\">payload</item>";
            while (text.size() < 1100000) text += item;
            NSMutableArray<DPScintillaEditorView *> *views = [NSMutableArray array];
            NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
            for (int index = 0; index < 2; ++index) {
                auto *view = [[DPScintillaEditorView alloc] initWithFrame:NSMakeRect(0,0,700,400)];
                [views addObject:view];
                check([view loadUTF8:[NSData dataWithBytes:text.data() length:text.size()] revision:0 error:nil], "load");
                view.wordWrapEnabled = YES;
                [view applyLexerNamed:name keywords:@[@"function return"] tabWidth:4 useTabs:NO folding:YES braceMatching:YES maximumStyleBytes:16000000];
                auto *sc = native(view);
                for (int style = 1; style < 20; ++style) [sc message:SCI_STYLESETSIZEFRACTIONAL wParam:style lParam:(style%2 ? 1900 : 1100)];
                if (index) {
                    auto *lexer = CreateLexer(name.UTF8String);
                    lexer->PropertySet("fold", "1"); lexer->WordListSet(0, "function return");
                    [sc message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(lexer)];
                    [sc message:SCI_COLOURISE wParam:0 lParam:-1];
                }
                auto *window = [[NSWindow alloc] initWithContentRect:view.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
                window.releasedWhenClosed = NO; window.contentView = view; [windows addObject:window];
                [window orderFront:nil]; draw(window);
            }
            wait(views[0], windows[0]);
            auto *a = native(views[0]); auto *b = native(views[1]);
            // The reference is laid out from scratch after its window metrics settle.
            [b message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
            [b message:SCI_SETWRAPMODE wParam:SC_WRAP_WORD];
            for (auto *sc : {a, b}) [sc message:SCI_SETFIRSTVISIBLELINE wParam:0];
            for (NSWindow *window in windows) draw(window);
            check([a message:SCI_WRAPCOUNT wParam:0] == [b message:SCI_WRAPCOUNT wParam:0], "async wrap count differs");
            for (size_t pos : {size_t(0), size_t(37), text.size()/2, text.size()-1}) {
                check([a message:SCI_POINTXFROMPOSITION wParam:0 lParam:pos] == [b message:SCI_POINTXFROMPOSITION wParam:0 lParam:pos], "async caret X differs");
                check([a message:SCI_POINTYFROMPOSITION wParam:0 lParam:pos] == [b message:SCI_POINTYFROMPOSITION wParam:0 lParam:pos], "async caret Y differs");
            }
            for (DPScintillaEditorView *view in views) [view invalidate];
            for (NSWindow *window in windows) [window close];
        }
        std::string text = "function f(){\n/*" + std::string(1100000,'a') + "*/\n}\n";
        auto *view = [[DPScintillaEditorView alloc] initWithFrame:NSMakeRect(0,0,700,400)];
        [view loadUTF8:[NSData dataWithBytes:text.data() length:text.size()] revision:0 error:nil];
        [view applyLexerNamed:@"cpp" keywords:@[] tabWidth:4 useTabs:NO folding:YES braceMatching:YES maximumStyleBytes:16000000];
        __block NSArray<NSNumber *> *pending = [view restoreContractedFoldHeaderLines:@[@0]];
        check(pending.count == 1, "fold recovery lost pending header");
        __weak DPScintillaEditorView *weakView = view;
        view.onFoldRecoveryProgress = ^{ pending = [weakView restoreContractedFoldHeaderLines:pending]; };
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
        while (pending.count) {
            check(std::chrono::steady_clock::now() < deadline, "fold recovery timeout");
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        }
        check([native(view) message:SCI_GETFOLDEXPANDED wParam:0] == 0, "fold header was not restored");
        [view invalidate];
        for (int action : {0, 1, 2, 3, 4}) {
            auto *foldView = [[DPScintillaEditorView alloc] initWithFrame:NSMakeRect(0,0,700,400)];
            [foldView loadUTF8:[NSData dataWithBytes:text.data() length:text.size()] revision:0 error:nil];
            [foldView applyLexerNamed:@"cpp" keywords:@[] tabWidth:4 useTabs:NO folding:YES braceMatching:YES maximumStyleBytes:16000000];
            check([foldView collapseAllFolds], "pending collapse command was rejected");
            DPScintillaEditorView *source = nil;
            if (action == 1) [foldView expandAllFolds];
            if (action == 2) [foldView loadUTF8:[NSData dataWithBytes:text.data() length:text.size()] revision:1 error:nil];
            if (action == 3) {
                source = [[DPScintillaEditorView alloc] initWithFrame:foldView.frame];
                [source loadUTF8:[NSData dataWithBytes:text.data() length:text.size()] revision:0 error:nil];
                [source applyLexerNamed:@"cpp" keywords:@[] tabWidth:4 useTabs:NO folding:YES braceMatching:YES maximumStyleBytes:16000000];
                [foldView shareDocumentWithView:source];
            }
            if (action == 4) {
                [native(foldView) message:SCI_SETTEXT wParam:0 lParam:reinterpret_cast<sptr_t>("function f(){\nreturn 1;\n}\n")];
                [native(foldView) message:SCI_COLOURISE wParam:0 lParam:-1];
                [native(foldView) message:SCI_COLOURISE wParam:0 lParam:-1];
            }
            wait(foldView, nil);
            check([native(foldView) message:SCI_GETFOLDEXPANDED wParam:0] == (action >= 1 && action <= 3 ? 1 : 0), "pending fold command lost or uncancelled");
            [foldView invalidate];
            [source invalidate];
        }
        std::string manyLines;
        for (int i = 0; i < 30000; ++i) manyLines += "function f(){\nif(true){\nreturn 1;\n}\n\n}\n\n";
        manyLines += "function eof(){";
        NSMutableArray<DPScintillaEditorView *> *foldViews = [NSMutableArray array];
        NSMutableArray<NSWindow *> *foldWindows = [NSMutableArray array];
        for (int index = 0; index < 2; ++index) {
            auto *v = [[DPScintillaEditorView alloc] initWithFrame:NSMakeRect(0,0,700,400)];
            [v loadUTF8:[NSData dataWithBytes:manyLines.data() length:manyLines.size()] revision:0 error:nil];
            [v applyLexerNamed:@"cpp" keywords:@[] tabWidth:4 useTabs:NO folding:YES braceMatching:YES maximumStyleBytes:16000000];
            if (index) {
                auto *raw = CreateLexer("cpp"); raw->PropertySet("fold", "1");
                [native(v) message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(raw)];
                [native(v) message:SCI_COLOURISE wParam:0 lParam:-1];
            }
            auto *w = [[NSWindow alloc] initWithContentRect:v.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            w.releasedWhenClosed = NO; w.contentView = v; [w orderFront:nil]; draw(w); wait(v, w);
            [native(v) message:SCI_SETSEL wParam:70 lParam:140];
            [native(v) message:SCI_SETFIRSTVISIBLELINE wParam:25];
            draw(w); wait(v, w);
            [foldViews addObject:v]; [foldWindows addObject:w];
        }
        auto *many = foldViews[0]; auto *reference = foldViews[1];
        for (auto *v : {many, reference}) [native(v) message:SCI_SETFIRSTVISIBLELINE wParam:25];
        // Recolour without changing bytes so both commands start from identical
        // settled font/scroll/fold state; only the asynchronous completion differs.
        [native(many) message:SCI_COLOURISE wParam:0 lParam:-1];
        [many collapseAllFolds]; wait(many, foldWindows[0]);
        [native(reference) message:SCI_FOLDALL wParam:SC_FOLDACTION_CONTRACT_EVERY_LEVEL];
        wait(reference, foldWindows[1]);
        check(!many.asynchronousWorkPending, "fold slices did not finish");
        for (int line = 0; line < [native(many) message:SCI_GETLINECOUNT]; ++line) {
            for (unsigned int message : {SCI_GETFOLDEXPANDED, SCI_GETLINEVISIBLE})
                check([native(many) message:message wParam:line] == [native(reference) message:message wParam:line], "sliced FoldAll differs from native at a header/visible line");
        }
        for (unsigned int message : {SCI_GETCURRENTPOS, SCI_GETANCHOR, SCI_GETFIRSTVISIBLELINE}) {
            if ([native(many) message:message] != [native(reference) message:message])
                std::cerr << "fold state message=" << message << " actual=" << [native(many) message:message] << " expected=" << [native(reference) message:message] << '\n';
            check([native(many) message:message] == [native(reference) message:message], "sliced FoldAll moved selection/viewport");
        }
        for (DPScintillaEditorView *v in foldViews) [v invalidate];
        for (NSWindow *w in foldWindows) [w close];
        std::cout << "PASS async style-dependent wrapping, caret geometry and fold recovery\n";
    } catch (const std::exception &error) { std::cerr << "FAIL " << error.what() << "\n"; return 1; }
}}
