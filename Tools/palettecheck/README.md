These fixtures are hand-written RGB histograms, created for this project. They contain no sampled artwork or third-party content. Each includes the exact expected palette, covering two distinct colors, exclusion of a low-weight color, and a dominant monochrome color.

With the Swift compiler installed, run from the repository root:

```sh
Tools/palettecheck/run.sh
```

Or invoke the script by its absolute path from any working directory. It compiles with absolute source paths so fixture lookup remains independent of the working directory, and removes its temporary binary on exit. Only tracked source files and `fixtures.json` are needed; no `mockups` directory or downloaded artwork is used.
