//
//  DeFeedbackHost-Bridging-Header.h
//  DeFeedbackHost
//
//  Exposes the C façade of the C++ audio engine to Swift. Deliberately a C interface: no Swift/C++
//  interop mode change, no name mangling, and no C++ types crossing into Swift.
//
//  - thanks to AI for laying out the interop so we dont need to worry about c++ types crossing over.

#import "Audio/DFHEngine.h"
#import "Audio/DFHDevices.h"
#import "Audio/DFHIO.h"
