# 근거 — openclaw 설치본 원본

검사자가 독립 검증할 수 있도록 인용한 것입니다. openclaw는 **MIT**이므로 인용에 문제가 없습니다.

확인할 것 두 가지:

1. `chunkMarkdown`이 **긴 줄을 segment로 쪼갠다** — 그래서 청크가 줄 중간에서 시작할 수 있습니다.
   (`maxChars = max(32, chunking.tokens * 4)`, `segments.push(coarse)`)
2. `recordShortTermRecalls`가 `continue`로 항목을 버려도 `store.updatedAt`과
   `memory.recall.recorded`는 그대로 나갑니다 — 조용한 실패의 정체입니다.

```
openclaw 2026.7.1-2 · MIT License · Copyright (c) 2026 OpenClaw Foundation
재현: npm pack openclaw@2026.7.1-2 후 아래 파일을 열면 같은 내용이 나온다.

----- dist/internal-ss-Qpla0.js : function chunkMarkdown -----
function chunkMarkdown(content, chunking) {
	const lines = content.split("\n");
	if (lines.length === 0) return [];
	const maxChars = Math.max(32, chunking.tokens * 4);
	const overlapChars = Math.max(0, chunking.overlap * 4);
	const chunks = [];
	let current = [];
	let currentChars = 0;
	const flush = () => {
		if (current.length === 0) return;
		const firstEntry = current[0];
		const lastEntry = current[current.length - 1];
		if (!firstEntry || !lastEntry) return;
		const text = current.map((entry) => entry.line).join("\n");
		const startLine = firstEntry.lineNo;
		const endLine = lastEntry.lineNo;
		chunks.push({
			startLine,
			endLine,
			text,
			hash: hashText(text),
			embeddingInput: buildTextEmbeddingInput(text)
		});
	};
	const carryOverlap = () => {
		if (overlapChars <= 0 || current.length === 0) {
			current = [];
			currentChars = 0;
			return;
		}
		let acc = 0;
		const kept = [];
		for (let i = current.length - 1; i >= 0; i -= 1) {
			const entry = current[i];
			if (!entry) continue;
			acc += estimateStringChars(entry.line) + 1;
			kept.unshift(entry);
			if (acc >= overlapChars) break;
		}
		current = kept;
		currentChars = acc;
	};
	for (let i = 0; i < lines.length; i += 1) {
		const line = lines[i] ?? "";
		const lineNo = i + 1;
		const segments = [];
		if (line.length === 0) segments.push("");
		else for (let start = 0; start < line.length;) {
			const coarse = truncateUtf16Safe(line.slice(start), maxChars);
			if (estimateStringChars(coarse) > maxChars) {
				const fineStep = Math.max(1, chunking.tokens);
				for (let j = 0; j < coarse.length;) {
					let end = Math.min(j + fineStep, coarse.length);
					const lastCodeUnit = coarse.charCodeAt(end - 1);
					if (lastCodeUnit >= 55296 && lastCodeUnit <= 56319 && end < coarse.length) end += 1;
					segments.push(coarse.slice(j, end));
					j = end;
				}
			} else segments.push(coarse);
			start += coarse.length;
		}
		for (const segment of segments) {
			const lineSize = estimateStringChars(segment) + 1;
			if (currentChars + lineSize > maxChars && current.length > 0) {
				flush();
				carryOverlap();
			}
			current.push({
				line: segment,
				lineNo
			});
			currentChars += lineSize;
		}
	}
	flush();
	return chunks;
}

----- dist/short-term-promotion-stx0l04M.js:576-581 : 오염 규칙 -----
const DREAMING_TRANSCRIPT_PROMPT_LINE_RE = /\[[^\]]*dreaming-narrative[^\]]*]\s*(?:User|Assistant):\s*Write a dream diary entry from these memory fragments:?/i;
const RAW_SESSION_METADATA_RE = /\bSession Key\b.{0,260}\bSession ID\b|\bSession ID\b.{0,260}\bSession Key\b/i;
const RAW_CONVERSATION_SUMMARY_RE = /^(?:[-*+]\s*)?Conversation Summary:/i;
const RAW_TRANSCRIPT_TURN_RE = /^(?:[-*+]\s*)?(?:user|assistant):\s/i;
const MEMORY_FLUSH_PROMPT_RE = /Save important context from this session to the daily memory file\.\s*STRICT RULES:/i;
const PROMOTION_SCORE_METADATA_RE = /\[\s*score=\d+(?:\.\d+)?\s+recalls=\d+\s+avg=\d+(?:\.\d+)?\s+source=memory\//i;

----- dist/short-term-promotion-stx0l04M.js : recordShortTermRecalls 앞부분 -----
async function recordShortTermRecalls(params) {
	const workspaceDir = params.workspaceDir?.trim();
	if (!workspaceDir) return;
	const query = params.query.trim();
	if (!query) return;
	const memoryResults = params.results.filter((result) => result.source === "memory");
	const relevant = memoryResults.filter((result) => isShortTermMemoryPath(result.path));
	const skipped = memoryResults.filter((result) => !isShortTermMemoryPath(result.path));
	if (relevant.length === 0 && skipped.length === 0) return;
	const nowMs = resolveMemoryCoreNowMs(params.nowMs);
	const nowIso = resolveMemoryCoreTimestamp(nowMs);
	if (relevant.length === 0) {
		await appendMemoryHostEvent(workspaceDir, buildMemoryRecallSkippedEvent({
			timestamp: nowIso,
			query,
			eligibleResultCount: relevant.length,
			skipped
		}));
		return;
	}
	const signalType = params.signalType ?? "recall";
	const queryHash = hashQuery(query);
	const todayBucket = normalizeIsoDay(params.dayBucket ?? "") ?? formatMemoryDreamingDay(nowMs, params.timezone);
	await withShortTermLock(workspaceDir, async () => {
		const store = await readStore(workspaceDir, nowIso);
		for (const result of relevant) {
			const normalizedPath = normalizeMemoryPath(result.path);
			const rawSnippet = normalizeSnippet(result.snippet);
			const snippet = truncateShortTermSnippet(rawSnippet);
			if (!rawSnippet || isContaminatedDreamingSnippet(rawSnippet)) continue;
			const claimHash = buildClaimHash(rawSnippet);
			const groundedKey = claimHash ? buildEntryKey({
```
