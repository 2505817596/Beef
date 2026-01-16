Wasm Debugging Notes

Source mapping relies on the DWARF file paths produced by Beef. For wasm builds the paths are
relative and resolve to:

- Project sources: `src/...`
- Core library sources: `BeefLibs/...`

Make sure your HTTP server root (the same root used by `--source-map-base`) serves both of
these directories. If you serve the build output directory directly, create junctions/symlinks
under that root so the paths resolve in the browser:

Windows (junctions):

```
mklink /J <http-root>\src <project-root>\src
mklink /J <http-root>\BeefLibs <beef-root>\BeefLibs
```

Non-Windows (symlinks):

```
ln -s <project-root>/src <http-root>/src
ln -s <beef-root>/BeefLibs <http-root>/BeefLibs
```
