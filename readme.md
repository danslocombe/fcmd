# FCMD
#### Autocomplete and quality of life for windows command line

![usage](https://raw.githubusercontent.com/danslocombe/zcmd/main/capture.gif)

Features:
- Smart autocomplete based on your local and global command history and environment. [^1]
- Text highlighting with Shift + navigation keys
- Quality of life keyboard shortcuts inspired by unix shells
- Path "compression" of the current directory in the prompt keeping it readable
- CD treats forward slash (/) like backslash (\) and doesn't require /D to switch drives.
- Add ls as an alias for dir

Shortcuts:
- Ctrl + F trigger a "Full" completion of the currently highlighted suggestion
- Tab trigger a "Partial" completion, or iterate through possible completions
- Ctrl + N / Ctrl + P move backwards and forwards through command history
- Ctrl + L to clear the screen
- Ctrl + C copies highlighted text when there is no running program, otherwise sends a kill signal as usual
- Ctrl + X cuts highlighted text.

 [^1]: Here local history is the set of commands run within a given directory and global history is all the commands run anywhere that do not have a relative path as an argument.

## Requirements to actually release  

Resizing of backing trie and file
Handling of multiline prompts and wrapping
Variable expansion
(Maybe) path completions

## Background

I wrote FishyCMD 7 years ago and have basically been using it every day since.

The completions make the command line feel so much more responsive in a way that is hard to articulate.
Using CMD without it now it feels like stumbling around in the dark, unsure of which files
and directories actually exist. Providing completions to long commands or parameters may save the most
typing time but the lookahead while you are cd'ing around is where the real benefit is.

FCMD is a full rewrite to address various bugs and limitations in the original implementation.
