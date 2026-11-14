// @auth/core as @auth/express uses it. npm nests it under @auth/express
// (its optional nodemailer peer wants ^7 || ^8, and the order-email relay's
// mail packages bring nodemailer 10), so tests find it from there rather than
// relying on it being hoisted to the top of node_modules.
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const fromExpress = createRequire(createRequire(import.meta.url).resolve("@auth/express"));
export const authCore = (subpath = "") => import(pathToFileURL(fromExpress.resolve("@auth/core" + subpath)).href);
