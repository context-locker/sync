// Context Locker's command: npx context-locker setup. MIT licence.
import { main } from "./cli.js";
import { FAILED } from "./setup.js";

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  () => {
    process.exitCode = FAILED;
  },
);
