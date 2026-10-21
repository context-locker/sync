// Text set beside Markdown in the files the compilers write.

// Control characters, and Unicode's line and paragraph separators
const LINE_BREAKS = /[\p{Cc}\p{Zl}\p{Zp}]+/gu;

/**
 * Text beside a Markdown link, on one line, with the characters that could
 * start another link, an autolink or a tag escaped.
 */
export function plainMarkdown(text: string): string {
  return text
    .replace(LINE_BREAKS, " ")
    .trim()
    .replace(/[\\[\]<>]/g, (character) => `\\${character}`);
}
