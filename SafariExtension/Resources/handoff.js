// handoff.js
// Rescriva Safari extension
//
// Handing pages and PDFs to the Rescriva app. The extension's native half
// (SafariWebExtensionHandler.swift) writes each hand-off into the Inbox folder Rescriva shares
// with its extensions, and Rescriva imports it when it opens. Files go across in 1 MB pieces,
// one native message each, so neither side holds much at once. Shared by the popup and the
// background script.

/** Safari ignores the id: a Safari extension's native messages always reach its own handler. */
const NATIVE_APP = "MBO.Scanner";
/** Bytes per native message, before base64. */
const PIECE_BYTES = 1024 * 1024;
/** The largest file the extension sends itself; anything bigger goes as a link for Rescriva to download. */
export const MAX_BYTES = 100 * 1024 * 1024;
/** Opening this link makes Rescriva import right away. */
export const INBOX_URL = "openscanner://inbox";

/** A localized string from _locales. */
export function t(key) {
	return browser.i18n.getMessage(key) || key;
}

/** The address when it's http or https (a page the popup can work on), else undefined. */
export function webAddress(url) {
	try {
		const parsed = new URL(url);
		return parsed.protocol === "http:" || parsed.protocol === "https:" ? parsed.href : undefined;
	} catch {
		return undefined;
	}
}

/**
 * The address when it's https, else undefined. Rescriva only records and downloads secure
 * addresses (App Transport Security would refuse plain http anyway), so a page's http address
 * is left off its hand-off and an http link can't be sent at all.
 */
export function secureAddress(url) {
	try {
		const parsed = new URL(url);
		return parsed.protocol === "https:" ? parsed.href : undefined;
	} catch {
		return undefined;
	}
}

/** True when the address's path ends in .pdf. */
export function looksLikePDFAddress(url) {
	try {
		return /\.pdf$/i.test(new URL(url).pathname);
	} catch {
		return false;
	}
}

/** The file name at the end of an address, without .pdf: "Lease%202026.pdf" → "Lease 2026". */
export function fileNameFromURL(url) {
	try {
		const last = new URL(url).pathname.split("/").filter(Boolean).pop() || "";
		return decoded(last).replace(/\.pdf$/i, "");
	} catch {
		return "";
	}
}

/** Sends a file to Rescriva in pieces. `kind` is "pdf" or "webPage". */
export async function sendFile(kind, blob, { title, sourceURL }, onProgress = () => {}) {
	if (blob.size > MAX_BYTES) {
		throw new Error(t("error_too_large"));
	}
	const { id } = await native({ action: "begin", kind, title: title || "", sourceURL: secureAddress(sourceURL) });
	try {
		const pieces = Math.max(1, Math.ceil(blob.size / PIECE_BYTES));
		for (let index = 0; index < pieces; index += 1) {
			const data = await base64(blob.slice(index * PIECE_BYTES, (index + 1) * PIECE_BYTES));
			await native({ action: "append", id, data });
			onProgress((index + 1) / pieces);
		}
		await native({ action: "commit", id });
	} catch (error) {
		native({ action: "cancel", id }).catch(() => {});
		throw error;
	}
}

/** Sends only the address; Rescriva downloads it (a PDF opens as a PDF, a page is saved as one). */
export async function sendLink(url, title) {
	const sourceURL = secureAddress(url);
	if (!sourceURL) {
		throw new Error(t("error_not_web"));
	}
	await native({ action: "link", sourceURL, title: title || "" });
}

/**
 * Sends the PDF at `url`. The extension downloads it with Safari's cookies, so a PDF behind a
 * sign-in comes too; when Safari won't let it (another site, no access yet), or the file is too
 * large, Rescriva gets the link and downloads it instead. Returns "file" or "link".
 */
export async function sendPDF(url, fallbackTitle, onProgress) {
	let download;
	try {
		download = await fetchPDF(url);
	} catch (error) {
		// A TypeError is the browser refusing the request; anything else is the server's answer.
		if (!(error instanceof TypeError)) {
			throw error;
		}
		await sendLink(url, fallbackTitle);
		return "link";
	}
	const title = download.title || fallbackTitle;
	if (download.blob.size > MAX_BYTES) {
		await sendLink(url, title);
		return "link";
	}
	await sendFile("pdf", download.blob, { title, sourceURL: url }, onProgress);
	return "file";
}

/** Asks Safari to open Rescriva, which imports straight away. Safari may ask the person first. */
export async function openRescriva(tabId) {
	await browser.tabs.update(tabId, { url: INBOX_URL });
}

/**
 * Runs in the page (scripting.executeScript): its HTML as Safari shows it now. CSS that scripts
 * added through the CSS object model is written back in, canvases become pictures, lazy images
 * load at once, and scripts are removed, since Rescriva saves the page without running them.
 * Must stay self-contained: Safari copies the function into the page.
 */
export function capturePage() {
	const rulesText = (sheet) => {
		try {
			return Array.from(sheet.cssRules, (rule) => rule.cssText).join("\n");
		} catch {
			return "";
		}
	};
	const sourceStyles = Array.from(document.querySelectorAll("style"));
	const sourceCanvases = Array.from(document.querySelectorAll("canvas"));
	const clone = document.documentElement.cloneNode(true);

	const styles = Array.from(clone.querySelectorAll("style"));
	sourceStyles.forEach((style, index) => {
		if (styles[index] && !style.textContent.trim() && style.sheet) {
			styles[index].textContent = rulesText(style.sheet);
		}
	});
	const adopted = Array.from(document.adoptedStyleSheets || [], rulesText).join("\n");
	if (adopted.trim()) {
		const style = document.createElement("style");
		style.textContent = adopted;
		(clone.querySelector("head") || clone).appendChild(style);
	}

	const canvases = Array.from(clone.querySelectorAll("canvas"));
	sourceCanvases.forEach((canvas, index) => {
		try {
			const picture = document.createElement("img");
			picture.src = canvas.toDataURL("image/png");
			picture.style.cssText = canvas.style.cssText;
			picture.style.width = `${canvas.clientWidth || canvas.width}px`;
			picture.style.height = `${canvas.clientHeight || canvas.height}px`;
			canvases[index]?.replaceWith(picture);
		} catch {
			// A canvas showing another site's images can't be read; it stays blank.
		}
	});

	clone.querySelectorAll("script, noscript").forEach((node) => node.remove());
	clone.querySelectorAll("img[loading]").forEach((image) => image.removeAttribute("loading"));
	return {
		html: `<!DOCTYPE html>\n${clone.outerHTML}`,
		title: document.title,
		url: location.href,
		contentType: document.contentType,
	};
}

// MARK: - Private

/** One native message. Rejects with the handler's sentence when it says no. */
async function native(message) {
	let reply;
	try {
		reply = await browser.runtime.sendNativeMessage(NATIVE_APP, message);
	} catch (error) {
		console.error("Rescriva: native message failed:", error);
		throw new Error(t("error_no_app"));
	}
	if (!reply || reply.ok !== true) {
		throw new Error((reply && reply.error) || t("error_no_app"));
	}
	return reply;
}

/** Downloads the PDF at `url` with Safari's cookies. */
async function fetchPDF(url) {
	const response = await fetch(url, { credentials: "include" });
	if (!response.ok) {
		throw new Error(t("error_download"));
	}
	const blob = await response.blob();
	if (!(await startsLikePDF(blob))) {
		throw new Error(t("error_not_pdf"));
	}
	return { blob, title: pdfTitle(response, url) };
}

/** True when "%PDF-" appears in the first kilobyte, where readers look for it. */
async function startsLikePDF(blob) {
	const head = new Uint8Array(await blob.slice(0, 1024).arrayBuffer());
	return String.fromCharCode(...head).includes("%PDF-");
}

/** The download's name: Content-Disposition's file name, else the address's, without .pdf. */
function pdfTitle(response, url) {
	const disposition = response.headers.get("Content-Disposition") || "";
	const encoded = /filename\*\s*=\s*(?:UTF-8'')?"?([^";]+)"?/i.exec(disposition);
	const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(disposition);
	const name = encoded ? decoded(encoded[1]) : plain ? plain[1] : fileNameFromURL(url);
	return name.replace(/\.pdf$/i, "").trim();
}

function decoded(text) {
	try {
		return decodeURIComponent(text);
	} catch {
		return text;
	}
}

/** A Blob's bytes as base64, without the data: prefix. */
function base64(blob) {
	return new Promise((resolve, reject) => {
		const reader = new FileReader();
		reader.onload = () => {
			const url = String(reader.result);
			resolve(url.slice(url.indexOf(",") + 1));
		};
		reader.onerror = () => reject(reader.error);
		reader.readAsDataURL(blob);
	});
}
