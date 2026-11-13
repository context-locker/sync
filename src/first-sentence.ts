// A preference's first sentence (G1-336): the rule it states, which an
// agent's file keeps when there's no room for the whole of it. One function
// decides it, for saving, for the files and for the editor, which imports
// this module on its own, so it needs nothing else.

/** The most characters an agent's preference or fact may give its first sentence */
export const FIRST_SENTENCE_MAX = 200;

/**
 * A text's first sentence and what follows it, so that first + rest is the
 * text. The sentence ends at the first full stop, question mark or
 * exclamation mark with a space or the line's end after it, or at the first
 * line break, whichever comes first, so context.locker and
 * docs/releases.md don't end one. rest starts with the space or line break
 * after it, and is empty when the text is one sentence.
 */
export function firstSentence(text: string): { first: string; rest: string } {
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === "\n") {
      return { first: text.slice(0, index), rest: text.slice(index) };
    }
    if (char === "." || char === "?" || char === "!") {
      const next = text[index + 1];
      if (next === undefined || next === " " || next === "\n") {
        return { first: text.slice(0, index + 1), rest: text.slice(index + 1) };
      }
    }
  }
  return { first: text, rest: "" };
}

const GRAPHEMES = new Intl.Segmenter("en", { granularity: "grapheme" });

/** How many characters a sentence has, as people count them: an emoji or an accented letter is one */
export function sentenceLength(sentence: string): number {
  let count = 0;
  for (const _ of GRAPHEMES.segment(sentence)) count++;
  return count;
}
