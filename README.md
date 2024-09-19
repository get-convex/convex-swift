# Convex for iOS

## Building

### The complete way

This library depends on Rust code built in the [`convex-mobile`](https://github.com/get-convex/convex-mobile) project. If you are working on changes there or want to incorporate recent changes from that code into this library, you should check out `convex-mobile` and work with this library as a submodule.

Once you've done that, starting from your `convex-mobile` repo:

1. `cd rust/`
2. `./build-ios.sh`
3. Open Xcode
4. Open `convex-mobile/ios`

That will build the full Rust library and build and bundle new XCFrameworks for target platforms in the `ios/` submodule (which points to this repository).

### The quick way

If you just want to work on the Swift side of things, you can just open a checked out version of this repo in Xcode. It should build and run standalone with previously bundled XCFrameworks.