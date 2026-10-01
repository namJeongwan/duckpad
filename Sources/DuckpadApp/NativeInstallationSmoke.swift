import Foundation
import Darwin
import DuckpadInfrastructure

enum NativeInstallationSmoke {
    static func checkTerminalCommandConflict() async {
        do {
            try await NativeInstallerClient().installTerminalCommand()
            fputs("FAIL: terminal installer replaced the conflicting command.\n", stderr)
            exit(1)
        } catch {
            guard String(describing: error).contains("Code=516") else {
                FileHandle.standardError.write(Data("Terminal registration XPC smoke failed: \(error)\n".utf8))
                exit(1)
            }
            print("PASS: authenticated terminal registration XPC preserves the existing command")
            exit(0)
        }
    }

    static func run(verifyOnly: Bool) async {
        do {
            guard let source = Bundle.main.url(forResource: "Clipboard", withExtension: "duckpad-plugin") else { throw CocoaError(.fileNoSuchFile) }
            let root = ManagedNativePackageStore.appRoot()
            let verifier = LocalExtensionPackageLoader(root: root, bundledPackages: [])
            let (package, files) = try await verifier.readPackage(at: source)
            if !verifyOnly { try await NativeInstallerClient().install(files: files) }
            let installed = root.appendingPathComponent(package.packageDigest + ".duckpad-plugin")
            let (verified, _) = try await verifier.readPackage(at: installed)
            guard verified.packageDigest == package.packageDigest,
                  let image = dlopen(installed.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL),
                  let entry = dlsym(image, "duckpad_native_abi_version") else {
                let detail = dlerror().map { String(cString: $0) } ?? "package mismatch"
                throw NSError(domain: "NativeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            let abi = unsafeBitCast(entry, to: (@convention(c) () -> UInt32).self)
            guard abi() == 1 else { throw CocoaError(.executableRuntimeMismatch) }
            print(verifyOnly ? "PASS: sandboxed relaunch loads managed native package without a picker" : "PASS: sandboxed app -> authenticated installer XPC -> fixed folder -> native load")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Native installation smoke failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
