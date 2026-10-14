//
//  LaTeXToOMML.swift
//  Rescriva (fork of Open Scanner)
//
//  A deliberately small LaTeX → OMML (Office Math Markup Language) converter
//  for the subset handwritten and printed notes actually use: fractions,
//  sub/superscripts, radicals, \left…\right delimiters, n-ary operators,
//  accents, Greek letters and the common operators and relations. Anything
//  outside the subset makes `convert` return nil so the caller falls back to
//  the equation's typeset picture (`EquationPictures`) or its linear text.
//

import Foundation

/// Converts a LaTeX math string to an OMML `<m:oMath>` element.
///
/// The output uses the `m:` (OMML) and `w:` (WordprocessingML) prefixes, which
/// the containing part must declare. Runs carry Cambria Math so Word renders
/// them with its math font.
enum LaTeXToOMML {
	/// Deepest nesting accepted before giving up: every sequence and every atom
	/// counts, so this bounds the parser's recursion whatever the input does
	/// (`\hat\hat\hat…` nests an atom per command, braces two levels each).
	static let maxDepth = 64
	/// Longest input accepted.
	static let maxLength = 4_000

	/// `<m:oMath>…</m:oMath>` for `latex`, or nil when it is empty or uses
	/// anything outside the supported subset.
	static func convert(_ latex: String) -> String? {
		let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
		do {
			let tokens = try tokenize(trimmed)
			var parser = Parser(tokens: tokens)
			let atoms = try parser.parseAll()
			let body = render(atoms)
			guard !body.isEmpty else { return nil }
			return "<m:oMath>" + body + "</m:oMath>"
		} catch {
			return nil
		}
	}

	// MARK: Tokens

	/// Why a parse failed; only used to unwind to `convert`.
	private enum ParseError: Error {
		case unsupported
		case unbalanced
		case unexpectedEnd
	}

	/// One lexical token of the LaTeX source.
	private enum Token: Equatable {
		case char(Character)
		case command(String)
		case open
		case close
		case sub
		case sup
		case space
	}

	private static func tokenize(_ source: String) throws -> [Token] {
		let characters = Array(source)
		var tokens: [Token] = []
		var index = 0
		// Every branch advances `index` by at least one.
		while index < characters.count {
			let character = characters[index]
			switch character {
			case "\\":
				guard index + 1 < characters.count else { throw ParseError.unexpectedEnd }
				let next = characters[index + 1]
				if next.isASCII && next.isLetter {
					var end = index + 1
					while end < characters.count, characters[end].isASCII, characters[end].isLetter { end += 1 }
					tokens.append(.command(String(characters[(index + 1)..<end])))
					index = end
				} else {
					tokens.append(.command(String(next)))
					index += 2
				}
			case "{":
				tokens.append(.open)
				index += 1
			case "}":
				tokens.append(.close)
				index += 1
			case "_":
				tokens.append(.sub)
				index += 1
			case "^":
				tokens.append(.sup)
				index += 1
			case "&", "#":
				throw ParseError.unsupported
			case "%":
				while index < characters.count, !characters[index].isNewline { index += 1 }
			default:
				if character.isWhitespace {
					if tokens.last != .space { tokens.append(.space) }
				} else {
					tokens.append(.char(character))
				}
				index += 1
			}
		}
		return tokens
	}

	// MARK: Atoms and rendering

	/// Math run styles: default (Word italicises letters), plain (upright) or bold.
	private enum MathStyle: Equatable {
		case normal, plain, bold
	}

	/// A parsed piece of math.
	private indirect enum Atom {
		/// Text that may merge with neighbouring runs of the same style.
		case run(String, MathStyle)
		/// A finished OMML element.
		case element(String)
		/// A brace group; flattened when rendered.
		case group([Atom])
	}

	private static func render(_ atoms: [Atom]) -> String {
		var output = ""
		var pending = ""
		var pendingStyle = MathStyle.normal
		func flush() {
			guard !pending.isEmpty else { return }
			output += mathRun(pending, style: pendingStyle)
			pending = ""
		}
		var stack: [ArraySlice<Atom>] = [atoms[...]]
		// Iterative flattening (no recursion); each step consumes one atom.
		while var top = stack.popLast() {
			guard let atom = top.popFirst() else { continue }
			stack.append(top)
			switch atom {
			case .run(let text, let style):
				if style != pendingStyle { flush() }
				pendingStyle = style
				pending += text
			case .element(let xml):
				flush()
				output += xml
			case .group(let inner):
				stack.append(inner[...])
			}
		}
		flush()
		return output
	}

	private static func mathRun(_ text: String, style: MathStyle) -> String {
		var properties = ""
		switch style {
		case .normal: break
		case .plain: properties = "<m:rPr><m:sty m:val=\"p\"/></m:rPr>"
		case .bold: properties = "<m:rPr><m:sty m:val=\"b\"/></m:rPr>"
		}
		return "<m:r>" + properties
			+ "<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/></w:rPr>"
			+ "<m:t xml:space=\"preserve\">" + OOXML.escape(text) + "</m:t></m:r>"
	}

	private static func restyle(_ atoms: [Atom], _ style: MathStyle) -> [Atom] {
		atoms.map { atom in
			switch atom {
			case .run(let text, _): return .run(text, style)
			case .group(let inner): return .group(restyle(inner, style))
			case .element: return atom
			}
		}
	}

	// MARK: Vocabulary

	private static let symbols: [String: String] = [
		"alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}",
		"epsilon": "\u{03F5}", "varepsilon": "\u{03B5}", "zeta": "\u{03B6}", "eta": "\u{03B7}",
		"theta": "\u{03B8}", "vartheta": "\u{03D1}", "iota": "\u{03B9}", "kappa": "\u{03BA}",
		"lambda": "\u{03BB}", "mu": "\u{03BC}", "nu": "\u{03BD}", "xi": "\u{03BE}",
		"omicron": "\u{03BF}", "pi": "\u{03C0}", "varpi": "\u{03D6}", "rho": "\u{03C1}",
		"varrho": "\u{03F1}", "sigma": "\u{03C3}", "varsigma": "\u{03C2}", "tau": "\u{03C4}",
		"upsilon": "\u{03C5}", "phi": "\u{03D5}", "varphi": "\u{03C6}", "chi": "\u{03C7}",
		"psi": "\u{03C8}", "omega": "\u{03C9}",
		"Gamma": "\u{0393}", "Delta": "\u{0394}", "Theta": "\u{0398}", "Lambda": "\u{039B}",
		"Xi": "\u{039E}", "Pi": "\u{03A0}", "Sigma": "\u{03A3}", "Upsilon": "\u{03A5}",
		"Phi": "\u{03A6}", "Psi": "\u{03A8}", "Omega": "\u{03A9}",
		"cdot": "\u{22C5}", "times": "\u{00D7}", "div": "\u{00F7}", "pm": "\u{00B1}", "mp": "\u{2213}",
		"leq": "\u{2264}", "le": "\u{2264}", "geq": "\u{2265}", "ge": "\u{2265}",
		"neq": "\u{2260}", "ne": "\u{2260}", "approx": "\u{2248}", "equiv": "\u{2261}",
		"sim": "\u{223C}", "simeq": "\u{2243}", "propto": "\u{221D}", "ll": "\u{226A}", "gg": "\u{226B}",
		"infty": "\u{221E}", "partial": "\u{2202}", "nabla": "\u{2207}", "circ": "\u{2218}",
		"degree": "\u{00B0}", "prime": "\u{2032}", "ast": "\u{2217}", "star": "\u{22C6}",
		"to": "\u{2192}", "rightarrow": "\u{2192}", "leftarrow": "\u{2190}", "gets": "\u{2190}",
		"leftrightarrow": "\u{2194}", "Rightarrow": "\u{21D2}", "Leftarrow": "\u{21D0}",
		"Leftrightarrow": "\u{21D4}", "implies": "\u{21D2}", "iff": "\u{21D4}", "mapsto": "\u{21A6}",
		"rightleftharpoons": "\u{21CC}", "uparrow": "\u{2191}", "downarrow": "\u{2193}",
		"in": "\u{2208}", "notin": "\u{2209}", "subset": "\u{2282}", "subseteq": "\u{2286}",
		"supset": "\u{2283}", "supseteq": "\u{2287}", "cup": "\u{222A}", "cap": "\u{2229}",
		"emptyset": "\u{2205}", "forall": "\u{2200}", "exists": "\u{2203}", "neg": "\u{00AC}",
		"land": "\u{2227}", "lor": "\u{2228}", "wedge": "\u{2227}", "vee": "\u{2228}",
		"cdots": "\u{22EF}", "ldots": "\u{2026}", "dots": "\u{2026}", "vdots": "\u{22EE}",
		"ddots": "\u{22F1}", "hbar": "\u{210F}", "ell": "\u{2113}", "angle": "\u{2220}",
		"perp": "\u{22A5}", "parallel": "\u{2225}", "therefore": "\u{2234}", "because": "\u{2235}",
		"langle": "\u{27E8}", "rangle": "\u{27E9}",
		"{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_", "|": "\u{2016}",
		",": "\u{2009}", ":": "\u{2005}", ";": "\u{2004}", " ": " ", "!": "",
		"quad": "\u{2003}", "qquad": "\u{2003}\u{2003}",
	]

	private static let functions: Set<String> = [
		"sin", "cos", "tan", "sec", "csc", "cot", "arcsin", "arccos", "arctan",
		"sinh", "cosh", "tanh", "log", "ln", "lg", "exp", "det", "gcd", "deg", "dim", "ker", "arg",
		"lim", "max", "min", "sup", "inf",
	]

	/// Functions whose subscript sits underneath (as an `m:limLow`).
	private static let limitFunctions: Set<String> = ["lim", "max", "min", "sup", "inf"]

	/// N-ary operators: character and limit placement.
	private static let naryOperators: [String: (chr: String, limLoc: String)] = [
		"sum": ("\u{2211}", "undOvr"), "prod": ("\u{220F}", "undOvr"), "coprod": ("\u{2210}", "undOvr"),
		"bigcup": ("\u{22C3}", "undOvr"), "bigcap": ("\u{22C2}", "undOvr"),
		"int": ("\u{222B}", "subSup"), "iint": ("\u{222C}", "subSup"),
		"iiint": ("\u{222D}", "subSup"), "oint": ("\u{222E}", "subSup"),
	]

	private static let accents: [String: String] = [
		"hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0305}", "vec": "\u{20D7}",
		"dot": "\u{0307}", "ddot": "\u{0308}", "tilde": "\u{0303}", "widetilde": "\u{0303}",
		"acute": "\u{0301}", "grave": "\u{0300}", "check": "\u{030C}", "breve": "\u{0306}",
	]

	private static let delimiters: [String: String] = [
		"{": "{", "}": "}", "|": "\u{2016}", "langle": "\u{27E8}", "rangle": "\u{27E9}",
		"lfloor": "\u{230A}", "rfloor": "\u{230B}", "lceil": "\u{2308}", "rceil": "\u{2309}",
		"lvert": "|", "rvert": "|", "lVert": "\u{2016}", "rVert": "\u{2016}", "vert": "|", "Vert": "\u{2016}",
	]

	/// Characters and commands that end an n-ary operand (`\sum_i x_i + 1`).
	private static let operandBreakChars: Set<Character> = ["+", "-", "=", "<", ">", ",", ";", "\u{2212}"]
	private static let operandBreakCommands: Set<String> = [
		"leq", "le", "geq", "ge", "neq", "ne", "approx", "equiv", "sim", "simeq", "propto",
		"to", "rightarrow", "Rightarrow", "implies", "iff", "pm", "mp", "ll", "gg",
	]

	// MARK: Parser

	/// Recursive-descent parser over the token list. Recursion depth is capped
	/// by `LaTeXToOMML.maxDepth`: `parseSequence` and `parseAtom` each count a
	/// level, and every other recursive path goes through one of them.
	private struct Parser {
		let tokens: [Token]
		var index = 0
		var depth = 0

		init(tokens: [Token]) {
			self.tokens = tokens
		}

		mutating func parseAll() throws -> [Atom] {
			let atoms = try parseSequence(stopAtBracket: false)
			guard index == tokens.count else { throw ParseError.unbalanced }
			return atoms
		}

		private var current: Token? { index < tokens.count ? tokens[index] : nil }

		private mutating func skipSpaces() {
			while current == .space { index += 1 }
		}

		private mutating func enter() throws {
			depth += 1
			guard depth <= LaTeXToOMML.maxDepth else { throw ParseError.unsupported }
		}

		/// Items until the end, a `}` or `\right` (neither consumed), or `]`
		/// when parsing a radical's index.
		private mutating func parseSequence(stopAtBracket: Bool) throws -> [Atom] {
			try enter()
			defer { depth -= 1 }
			var atoms: [Atom] = []
			while let token = current {
				if token == .close || token == .command("right") { break }
				if stopAtBracket, token == .char("]") { break }
				if token == .space {
					index += 1
					continue
				}
				let start = index
				atoms.append(try parseItem(stopAtBracket: stopAtBracket))
				guard index > start else { throw ParseError.unsupported }
			}
			return atoms
		}

		/// One atom with its scripts, or an n-ary operator with its operand.
		private mutating func parseItem(stopAtBracket: Bool) throws -> Atom {
			if case .command(let name) = current, let op = LaTeXToOMML.naryOperators[name] {
				index += 1
				return try parseNary(chr: op.chr, limLoc: op.limLoc, stopAtBracket: stopAtBracket)
			}
			if case .command(let name) = current, LaTeXToOMML.limitFunctions.contains(name) {
				index += 1
				let scripts = try parseScripts()
				let base = Atom.run(name, .plain)
				if let lower = scripts.sub, scripts.sup == nil {
					return .element("<m:limLow><m:e>\(render([base]))</m:e><m:lim>\(render(lower))</m:lim></m:limLow>")
				}
				return attach(base, scripts)
			}
			let base = try parseAtom()
			let scripts = try parseScripts()
			return attach(base, scripts)
		}

		private func attach(_ base: Atom, _ scripts: (sub: [Atom]?, sup: [Atom]?)) -> Atom {
			let e = "<m:e>" + render([base]) + "</m:e>"
			switch (scripts.sub, scripts.sup) {
			case (nil, nil):
				return base
			case (let sub?, nil):
				return .element("<m:sSub>\(e)<m:sub>\(render(sub))</m:sub></m:sSub>")
			case (nil, let sup?):
				return .element("<m:sSup>\(e)<m:sup>\(render(sup))</m:sup></m:sSup>")
			case (let sub?, let sup?):
				return .element("<m:sSubSup>\(e)<m:sub>\(render(sub))</m:sub><m:sup>\(render(sup))</m:sup></m:sSubSup>")
			}
		}

		private mutating func parseScripts() throws -> (sub: [Atom]?, sup: [Atom]?) {
			var sub: [Atom]?
			var sup: [Atom]?
			for _ in 0..<3 {
				skipSpaces()
				if current == .command("limits") || current == .command("nolimits") {
					index += 1
					continue
				}
				if current == .sub {
					guard sub == nil else { throw ParseError.unsupported }
					index += 1
					sub = try parseArgument()
				} else if current == .sup {
					guard sup == nil else { throw ParseError.unsupported }
					index += 1
					sup = try parseArgument()
				} else {
					break
				}
			}
			return (sub, sup)
		}

		/// A brace group, a single character or a single command.
		private mutating func parseArgument() throws -> [Atom] {
			skipSpaces()
			guard let token = current else { throw ParseError.unexpectedEnd }
			switch token {
			case .open:
				return [try parseAtom()]
			case .char(let character):
				index += 1
				return [Self.charAtom(character)]
			case .command:
				return [try parseAtom()]
			case .close, .sub, .sup, .space:
				throw ParseError.unsupported
			}
		}

		private mutating func parseGroup() throws -> [Atom] {
			skipSpaces()
			guard current == .open else { throw ParseError.unsupported }
			index += 1
			let inner = try parseSequence(stopAtBracket: false)
			guard current == .close else { throw ParseError.unbalanced }
			index += 1
			return inner
		}

		private mutating func parseAtom() throws -> Atom {
			try enter()
			defer { depth -= 1 }
			skipSpaces()
			guard let token = current else { throw ParseError.unexpectedEnd }
			switch token {
			case .open:
				return .group(try parseGroup())
			case .char(let character):
				index += 1
				return Self.charAtom(character)
			case .command(let name):
				index += 1
				return try parseCommand(name)
			case .sub, .sup:
				return .group([])
			case .close, .space:
				throw ParseError.unbalanced
			}
		}

		private static func charAtom(_ character: Character) -> Atom {
			switch character {
			case "-": return .run("\u{2212}", .normal)
			case "'": return .run("\u{2032}", .normal)
			default: return .run(String(character), .normal)
			}
		}

		private mutating func parseCommand(_ name: String) throws -> Atom {
			if let symbol = LaTeXToOMML.symbols[name] { return .run(symbol, .normal) }
			if LaTeXToOMML.functions.contains(name) { return .run(name, .plain) }
			if let accent = LaTeXToOMML.accents[name] {
				let base = try parseArgument()
				return .element("<m:acc><m:accPr><m:chr m:val=\"\(accent)\"/></m:accPr><m:e>\(render(base))</m:e></m:acc>")
			}
			switch name {
			case "frac", "dfrac", "tfrac", "cfrac":
				let numerator = try parseArgument()
				let denominator = try parseArgument()
				return .element("<m:f><m:num>\(render(numerator))</m:num><m:den>\(render(denominator))</m:den></m:f>")
			case "sqrt":
				return try parseRadical()
			case "left":
				let open = try parseDelimiter()
				let inner = try parseSequence(stopAtBracket: false)
				guard current == .command("right") else { throw ParseError.unbalanced }
				index += 1
				let close = try parseDelimiter()
				return .element("<m:d><m:dPr><m:begChr m:val=\"\(OOXML.escape(open))\"/><m:endChr m:val=\"\(OOXML.escape(close))\"/></m:dPr><m:e>\(render(inner))</m:e></m:d>")
			case "text", "textrm", "textnormal", "mathrm", "operatorname", "mbox", "textit":
				return .run(try parseRawText(), .plain)
			case "mathbf", "textbf", "boldsymbol", "bm":
				return .group(LaTeXToOMML.restyle(try parseArgument(), .bold))
			case "mathit", "mathnormal":
				return .group(try parseArgument())
			case "overline", "underline":
				let base = try parseArgument()
				let position = name == "overline" ? "top" : "bot"
				return .element("<m:bar><m:barPr><m:pos m:val=\"\(position)\"/></m:barPr><m:e>\(render(base))</m:e></m:bar>")
			case "displaystyle", "textstyle", "limits", "nolimits", "big", "Big", "bigg", "Bigg":
				return .group([])
			default:
				throw ParseError.unsupported
			}
		}

		private mutating func parseRadical() throws -> Atom {
			skipSpaces()
			var degree: [Atom] = []
			if current == .char("[") {
				index += 1
				degree = try parseSequence(stopAtBracket: true)
				guard current == .char("]") else { throw ParseError.unbalanced }
				index += 1
			}
			let base = try parseArgument()
			let hide = degree.isEmpty ? "<m:radPr><m:degHide m:val=\"1\"/></m:radPr>" : ""
			return .element("<m:rad>\(hide)<m:deg>\(render(degree))</m:deg><m:e>\(render(base))</m:e></m:rad>")
		}

		private mutating func parseDelimiter() throws -> String {
			skipSpaces()
			guard let token = current else { throw ParseError.unexpectedEnd }
			index += 1
			switch token {
			case .char("."):
				return ""
			case .char("<"):
				return "\u{27E8}"
			case .char(">"):
				return "\u{27E9}"
			case .char(let character) where "()[]|/".contains(character):
				return String(character)
			case .command(let name):
				guard let delimiter = LaTeXToOMML.delimiters[name] else { throw ParseError.unsupported }
				return delimiter
			default:
				throw ParseError.unsupported
			}
		}

		/// The literal contents of a `{…}` group (for `\text`), spaces kept.
		private mutating func parseRawText() throws -> String {
			skipSpaces()
			guard current == .open else { throw ParseError.unsupported }
			index += 1
			var text = ""
			while let token = current, token != .close {
				switch token {
				case .char(let character): text.append(character)
				case .space: text.append(" ")
				case .command(let name):
					guard let symbol = LaTeXToOMML.symbols[name] else { throw ParseError.unsupported }
					text += symbol
				case .open, .close, .sub, .sup:
					throw ParseError.unsupported
				}
				index += 1
			}
			guard current == .close else { throw ParseError.unbalanced }
			index += 1
			return text
		}

		private mutating func parseNary(chr: String, limLoc: String, stopAtBracket: Bool) throws -> Atom {
			let scripts = try parseScripts()
			var operand: [Atom] = []
			while let token = current {
				if token == .close || token == .command("right") { break }
				if stopAtBracket, token == .char("]") { break }
				if case .char(let character) = token, LaTeXToOMML.operandBreakChars.contains(character) { break }
				if case .command(let name) = token,
				   LaTeXToOMML.operandBreakCommands.contains(name) || LaTeXToOMML.naryOperators[name] != nil { break }
				if token == .space {
					index += 1
					continue
				}
				let start = index
				operand.append(try parseItem(stopAtBracket: stopAtBracket))
				guard index > start else { throw ParseError.unsupported }
			}
			var properties = "<m:chr m:val=\"\(chr)\"/><m:limLoc m:val=\"\(limLoc)\"/>"
			if scripts.sub == nil { properties += "<m:subHide m:val=\"1\"/>" }
			if scripts.sup == nil { properties += "<m:supHide m:val=\"1\"/>" }
			return .element("<m:nary><m:naryPr>\(properties)</m:naryPr>"
				+ "<m:sub>\(render(scripts.sub ?? []))</m:sub><m:sup>\(render(scripts.sup ?? []))</m:sup>"
				+ "<m:e>\(render(operand))</m:e></m:nary>")
		}

		private func render(_ atoms: [Atom]) -> String { LaTeXToOMML.render(atoms) }
	}
}

// MARK: - Typeset pictures

/// The picture route for equations the converter can't handle: the export
/// renders each such equation from the app's own equation preview (on the
/// main actor, before the renderers run) and carries the PNG in
/// `RenderOptions.assets` under `assetKey(for:)`, where the Word and
/// PowerPoint renderers embed it with the LaTeX as alt text. This half is
/// Foundation-only; `ExportService` adds the rendering.
enum EquationPictures {
	/// Prefix that keeps equation keys clear of figure asset ids (UUID strings).
	static let keyPrefix = "equation:"
	/// Pixels per point the pictures are rendered at.
	static let scale = 3.0

	/// The `RenderOptions.assets` key of the picture for `latex`.
	static func assetKey(for latex: String) -> String {
		keyPrefix + latex.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Whether an equation needs a picture: the converter can't make OMML of it.
	static func needsPicture(_ latex: String) -> Bool {
		LaTeXToOMML.convert(latex) == nil
	}

	/// The picture's size in EMU at its natural point size (pixels ÷ `scale`),
	/// shrunk to `maxWidthInches` when wider.
	static func extent(of info: RescrivaImageInfo, maxWidthInches: Double) -> (cx: Int, cy: Int) {
		var width = Double(info.pixelWidth) / scale / 72
		var height = Double(info.pixelHeight) / scale / 72
		if maxWidthInches > 0, width > maxWidthInches {
			height *= maxWidthInches / width
			width = maxWidthInches
		}
		return (OOXML.emu(inches: width), OOXML.emu(inches: height))
	}
}
