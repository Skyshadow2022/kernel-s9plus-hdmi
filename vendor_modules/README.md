# vendor_modules

Staging templates for GKI-like module packaging.

- `modules.load` — ordered list of module names (without `.ko`)
- Built `.ko` files and depmaps are produced by `build_gkilike.sh` into `out_gkilike/modules/` and copied into `AnyKernel3/modules/system/lib/modules/`
