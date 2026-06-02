let's focus on the core, from first principles.


core requirements:
- maximize throughput
- minimize latency
- minimize memory usage
- minimize disk usage
- hardware abastraction layer for the various hardware platforms (Apple Silicon (M3), linux, and embedded platforms)
- streaming input (linear Pulse Code Modulation) and output
- configuration driven (precision (float32, float64, int8, int16, int32, int64, ...), sample rate (8k, 16k, 24k, 48k, 96k, ...), block size (128, 256, 512, 1024, 2048, ...), ...) for the entire pipeline and for individual processing blocks

defer, out of scope for now:
- 

potential languages (not decided yet):
- C
- Rust
- Zig

constraints:
- HAL : must run on Apple Silicon (M3), linux, and embedded platforms
- developmeent will be done on M3, single machine, linux and embedded platforms must be accounted for in the architecture but testing deferred.

workflow notes:
- we want first to create a set of specification documents in @specifications/: those will be the single source of truth, and code will be generated from them. Specification files must use category theory (and its subfields, such as yoneda lemma and others), mathematical formulation. a specifications/catalog.md documenting all the semantic and definitions which are used in the specification documents.

software engineering:
- draw inspiration from the architecture design in @zig_engineering: a SDR project which uses an architecture we could maybe draw inspiration from for creating a real time udio processing library (ability to create pipelines, computational graphs, etc.)
- and examples/ folder, using pan audio library in order to create the data required to create the @notes/1.md vizualization (parsing raw input LPCM, pipeline for audio processing, collecting output, etc. ). can use python for vizualisation (animation rendering, ...).
- a script folder, where we can for example create a python script to parse common audio file formats (wav, flac, mp3, ...) into LPCM raw data files, for testing pan audio library.
