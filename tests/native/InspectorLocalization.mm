#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#include <util.h>
#include <unistd.h>
#include <unordered_map>
#include <string>
#include "ghostty.h"
#define IMGUI_USE_WCHAR32 1
#include "dcimgui.h"

static NSDictionary<NSString *, NSString *> *catalog;
static NSMutableSet<NSString *> *requested;
static std::unordered_map<std::string, std::string> translations;
static const char *translate(const char *key) {
    NSString *source = @(key);
    [requested addObject:source];
    NSString *value = catalog[source] ?: source;
    auto found = translations.emplace(key, value.UTF8String);
    return found.first->second.c_str();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSCAssert(argc == 3, @"Usage: test /resource/root /output/root");
        NSCAssert(ghostty_init(argc, argv) == 0, @"Ghostty initialization failed");
        ghostty_config_t config = ghostty_config_new();
        NSCAssert(config != nullptr, @"Configuration unavailable");
        ghostty_config_finalize(config);
        ghostty_runtime_config_s callbacks = {};
        callbacks.wakeup_cb = [](void *) {};
        callbacks.action_cb = [](ghostty_app_t, ghostty_target_s, ghostty_action_s) { return false; };
        callbacks.read_clipboard_cb = [](void *, ghostty_clipboard_e, void *) { return false; };
        ghostty_app_t engine = ghostty_app_new(&callbacks, config);
        NSCAssert(engine != nullptr, @"Engine unavailable");
        ghostty_config_free(config);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        NSView *terminal = window.contentView;
        terminal.wantsLayer = YES;
        int master = -1, slave = -1;
        NSCAssert(openpty(&master, &slave, nullptr, nullptr, nullptr) == 0, @"PTY unavailable");
        std::string fd = std::to_string(master);
        ghostty_env_var_s variable = {"DUCKPAD_HOST_PTY_FD", fd.c_str()};
        ghostty_surface_config_s surfaceConfig = ghostty_surface_config_new();
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS;
        surfaceConfig.platform.macos.nsview = (__bridge void *)terminal;
        surfaceConfig.scale_factor = 1;
        surfaceConfig.font_size = 12;
        surfaceConfig.env_vars = &variable;
        surfaceConfig.env_var_count = 1;
        ghostty_surface_t surface = ghostty_surface_new(engine, &surfaceConfig);
        NSCAssert(surface != nullptr, @"Surface unavailable");
        ghostty_surface_set_size(surface, 1000, 700);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSCAssert(device != nil, @"Metal unavailable");
        id<MTLCommandQueue> queue = [device newCommandQueue];
        for (NSString *language in @[@"en", @"ko", @"ja", @"zh-Hans", @"de", @"fr", @"it", @"pt-BR"]) {
            NSString *file = [NSString stringWithFormat:@"%s/%@.lproj/Localizable.strings", argv[1], language];
            catalog = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:file] options:NSPropertyListImmutable format:nullptr error:nil];
            NSCAssert(catalog != nil, @"Locale catalog missing");
            requested = [NSMutableSet set]; translations.clear();
            NSString *fontName = [language isEqual:@"ko"] ? @"AppleSDGothicNeo-Regular" :
                [language isEqual:@"ja"] ? @"HiraginoSans-W3" : [language isEqual:@"zh-Hans"] ? @"STHeitiSC-Light" : @"Menlo-Regular";
            CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)fontName, 16, nullptr);
            NSURL *fontURL = CFBridgingRelease(CTFontCopyAttribute(font, kCTFontURLAttribute));
            CFRelease(font);
            NSCAssert(fontURL != nil, @"Font path unavailable");
            duckpad_inspector_set_translation_callback(translate, fontURL.path.UTF8String);
            ghostty_inspector_t inspector = ghostty_surface_inspector(surface);
            NSCAssert(inspector != nullptr, @"Inspector unavailable");
            NSCAssert(ghostty_inspector_metal_init(inspector, (__bridge_retained void *)device), @"Inspector Metal setup failed");
            ghostty_inspector_set_content_scale(inspector, 1, 1);
            ghostty_inspector_set_size(inspector, 1000, 700);
            MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1000 height:700 mipmapped:NO];
            textureDescriptor.storageMode = MTLStorageModeShared;
            textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
            for (int frame = 0; frame < 3; frame++) {
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = texture;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1);
                id<MTLCommandBuffer> command = [queue commandBuffer];
                ghostty_inspector_metal_render(inspector, (__bridge_retained void *)command, (__bridge_retained void *)pass);
                [command commit]; [command waitUntilCompleted];
                NSCAssert(command.status == MTLCommandBufferStatusCompleted, @"GPU command failed");
            }
            NSCAssert([requested containsObject:@"Terminal"] && [requested containsObject:@"Keyboard"] && [requested containsObject:@"Surface"], @"Engine did not request localized dock titles");
            NSCAssert(requested.count >= 8, @"Engine did not localize Inspector fields");
            NSCAssert([requested containsObject:@"Hide tab bar###HideTabBar"], @"Built-in docking menus were not localized");
            uint32_t probe = [language isEqual:@"ko"] ? 0xD130 : [language isEqual:@"ja"] ? 0x753B : [language isEqual:@"zh-Hans"] ? 0x7EC8 : 0x0041;
            // EndFrame clears the bound font; inspect the atlas's actual font.
            ImFont *atlasFont = ImGui_GetIO()->Fonts->Fonts.Data[0];
            ImFontBaked *baked = ImFont_GetFontBaked(atlasFont, 32);
            NSCAssert(baked && ImFontBaked_FindGlyphNoFallback(baked, probe), @"Inspector font cannot render %@ (U+%04X)", language, probe);
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:1000 pixelsHigh:700 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:4000 bitsPerPixel:32];
            [texture getBytes:bitmap.bitmapData bytesPerRow:4000 fromRegion:MTLRegionMake2D(0, 0, 1000, 700) mipmapLevel:0];
            for (size_t i = 0; i < 1000 * 700 * 4; i += 4) std::swap(bitmap.bitmapData[i], bitmap.bitmapData[i+2]);
            NSString *output = [NSString stringWithFormat:@"%s/inspector-%@.png", argv[2], language];
            NSCAssert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output atomically:YES], @"Snapshot write failed");
            printf("PASS %s: %lu localized engine requests; font %s\n", language.UTF8String, (unsigned long)requested.count, fontURL.path.UTF8String);
            ghostty_inspector_metal_shutdown(inspector);
            ghostty_inspector_free(surface);
        }
        ghostty_surface_free(surface);
        close(slave); close(master);
        ghostty_app_free(engine);
        [window close];
        printf("PASS: Inspector renders all eight locales through the actual Metal engine without a shell process\n");
    }
}
