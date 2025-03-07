// MIT Licensed.

class TmdLib {
	#wasm;
	#inputTmdDataLength;

	constructor(wasm) {
		this.wasm = wasm;
		this.#inputTmdDataLength = 0;
	}

	#readCString(offset) {
		var bytes = new Uint8Array(this.wasm.memory.buffer, offset);
		for (let i = 0; i < bytes.length; i++) {
			if (bytes[i] == 0) {
				bytes = bytes.slice(0, i)
				break;
			}
		}
		return new TextDecoder().decode(bytes);
	}

	#writeTextData(offset, textData) {
		const buffer = this.wasm.memory.buffer;

		const dataOffset = offset + 4;
		const byteArray = new Uint8Array(buffer, dataOffset);
		const { read, written } = new TextEncoder().encodeInto(textData, byteArray);
		if (read < textData.length) {
			throw new Error("Text data is not encoded fully (" + read + + " < " + textData.length + ")");
		}

		const view = new DataView(buffer, offset);
		view.setInt32(0, written, true);
		return written;
	}

	#readTextData(offset) {
		const buffer = this.wasm.memory.buffer;

		const view = new DataView(buffer, offset);
		const length = view.getUint32(0, true);
		if (length == 0) {
			return null;
		}

		const byteArray = new Uint8Array(buffer, offset+4, length);
		return new TextDecoder().decode(byteArray);
	}

	#bufferOffset() {
		const offset = this.wasm.buffer_offset();
		if (offset < 0) {
			throw new Error(this.#readCString(-offset));
		}
		return offset;
	}

	version() {
		const offset = this.wasm.lib_version();
		if (offset < 0) {
			throw new Error(this.#readCString(-offset));
		}
		return this.#readCString(offset);
	}

	// tmdText should be a JS string.
	setInputTmd(tmdText) {
		const offset = this.#bufferOffset();
		this.#inputTmdDataLength = this.#writeTextData(offset, tmdText);
	}

	generateHtml(options) {
		const bufferOffset = this.#bufferOffset() + 4 + this.#inputTmdDataLength;

		const enabledCustomApps = options?.enabledCustomApps ?? "";
		const identSuffix = options?.identSuffix ?? "";
		const autoIdentSuffix = options?.autoIdentSuffix ?? "";
		const renderRoot = options?.renderRoot ?? true;
		this.#writeTextData(bufferOffset, `
@@@ #enabledCustomApps
'''
${enabledCustomApps}
'''

@@@ #identSuffix
'''
${identSuffix}
'''

@@@ #autoIdentSuffix
'''
${autoIdentSuffix}
'''

@@@ #renderRoot
'''
${renderRoot}
'''
`);

		const offset = this.wasm.tmd_to_html();
		if (offset < 0) {
			throw new Error(this.#readCString(-offset));
		}
		return this.#readTextData(offset);
	}

	generateHtmlFromTmd(tmdText, options) {
		this.setInputTmd(tmdText);
		return this.generateHtml(options);
	}

	format() {
		const bufferOffset = this.#bufferOffset() + 4 + this.#inputTmdDataLength;
		this.#writeTextData(bufferOffset, "");

		const offset = this.wasm.tmd_format();
		if (offset < 0) {
			throw new Error(this.#readCString(-offset));
		}
		return this.#readTextData(offset);
	}

	formatTmd(tmdText) {
		this.setInputTmd(tmdText);
		return this.format();
	}
}

async function initTmdLib() {
	const imports = {env: {
		print(addr, len, addr2, len2, extraInt32) {
			try {
				const buff = memory.buffer.slice(addr, addr + len);
				const message = new TextDecoder().decode(buff);
				const buff2 = memory.buffer.slice(addr2, addr2 + len2);
				const message2 = new TextDecoder().decode(buff2);
				console.log(message, message2, extraInt32);
			} catch (err) {
				console.error("log error.");
			}
		}
	}};
	const wasmBinary = Uint8Array.from(atob(wasmBase64), c => c.charCodeAt(0));
	try {
		const { instance } = await WebAssembly.instantiate(wasmBinary, imports);
		const wasm = {
			buffer_offset: instance.exports.buffer_offset,
			lib_version: instance.exports.lib_version,
			tmd_to_html: instance.exports.tmd_to_html,
			tmd_format: instance.exports.tmd_format,
			memory: instance.exports.memory
		}
		return new TmdLib(wasm); 
	} catch (err) {
		throw err;
	}
}

window.initTmdLib = initTmdLib;

const wasmBase64 = "<wasm-file-as-base64-string>";
