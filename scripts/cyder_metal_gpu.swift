import Foundation
import Metal

/// `CyderSwift --metal-gpu-family`: prints the Metal GPU family of the default
/// device for the launcher's DXMT gate. DXMT needs GPU Family Mac 2; Intel
/// Macs with a Mac 1 GPU (for example a Kepler GTX 780M under OpenCore) abort
/// in Metal when DXMT creates its first render pipeline.
enum CyderMetalGPU {
    enum Family: String { case mac2, mac1, none }

    // The macOS 27 SDK deprecates .mac2 in favour of .apple7, which excludes
    // every Intel GPU; .mac2 is still the check that separates the two.
    static func family(of device: MTLDevice?) -> Family {
        guard let device else { return .none }
        return device.supportsFamily(.mac2) ? .mac2 : .mac1
    }

    static func run(arguments: [String],
                    device: () -> MTLDevice? = { MTLCreateSystemDefaultDevice() },
                    output: (String) -> Void = { print($0) }) -> Int32 {
        guard arguments.count == 2, arguments[1] == "--metal-gpu-family" else { return 64 }
        output(family(of: device()).rawValue)
        return 0
    }
}
