# UI golden transcripts

Golden files are UTF-8 text with LF line endings. Tests force transcript mode
(`--no-clear` or `BYOK_UI_HISTORY=true`), disable color, use a fixed 60-column
terminal layout, and compare visible text only; ANSI escape sequences, cursor
movement, and terminal-control bytes are not part of this format. Dynamic
values in a fixture are deliberately stable sample values.

The API-key fixture uses the marker `<masked input>` solely to document an
interactive test action. It is never an API key and a captured transcript must
not contain the supplied secret.
