# synchronous — product spec

**Your second brain for the internet.**

Save anything from TikTok, Instagram, YouTube, X, Reddit, or anywhere else. synchronous understands what you consume, connects it with everything you’ve saved before, and turns your endless feed into knowledge you can actually use.

> Save anything. Find it when you need it.

This is an **iOS-first** product. Capture happens through the iOS share sheet. The interface should feel like memory and search — not a chatbot — even though the story is an AI-powered second brain for everything you consume online.

---

## Positioning

Social content is the wedge: people save hundreds of TikToks, Reels, posts, tweets, and Reddit threads and almost never extract knowledge from them.

Then it expands:

TikTok + Instagram → YouTube + X + Reddit → articles + links + screenshots → eventually everything you consume.

**Bookmark app:** here’s everything you saved.  
**Keep:** here’s what everything you’ve saved actually means.

It understands it, remembers it, connects it, notices patterns across it, lets you ask questions about it, and eventually develops a model of the knowledge and interests you’ve accumulated.

Use “AI-powered second brain” in the bigger narrative. Do not put “AI summarize,” “AI organize,” or “Ask AI” on every button. The product can feel simple while the story is ambitious.

Possible lines:

- Save anything. Find it when you need it.
- Everything worth remembering.
- The home for everything you save.
- Never lose something you found online again.
- Your second brain for the internet.

Avoid: “AI-powered second brain for social media content” as the only frame (too narrow). Avoid “AI knowledge management platform” and “AI bookmark organizer.”

---

## 1. Concept

A mobile-first personal library for everything you find online.

Users save videos, posts, screenshots, links, products, places, ideas, articles, and other content into one place. The app automatically understands and organizes what was saved, connects related things, makes everything searchable, and resurfaces useful information later.

The product should **not feel like an AI app**. Intelligence happens quietly in the background.

### Core loop

See something → share it to the app → forget about it → find/use it later

The goal is to solve the problem of having hundreds or thousands of saved TikToks, Reels, posts, screenshots, bookmarks, and links that users rarely look at again.

---

## 2. Core product principles

1. Saving should take less than 2 seconds
2. Users should not have to manually organize things
3. Every save should remain useful even if enrichment fails
4. Search should work based on vague memories, not just exact keywords
5. The app should connect information across different platforms
6. Old saves should become more valuable over time
7. The app should feel like memory/search infrastructure, not a chatbot
8. Everything should be private by default
9. Capture first, enrichment second
10. The original source should always remain accessible

---

## 3. Platform limitation / ingestion strategy

Do not design the product around automatically importing someone’s entire Instagram or TikTok saved folder. Platform APIs may not provide reliable consumer access to saved/favorited content.

**The iOS share sheet is the primary capture mechanism.**

TikTok / Instagram / YouTube / Reddit / browser → Share → Keep.

The app immediately saves the URL/content and performs processing asynchronously. Later, additional integrations can be added where officially supported.

---

## 4. Supported content

### v1

**Social:** TikTok, Instagram Reels, Instagram posts, YouTube, YouTube Shorts, X, Reddit, Spotify (tracks, artists, playlists, albums)  
**Web:** websites, articles, blog posts, GitHub repositories, products, normal URLs  
**Personal:** screenshots, images, copied text, notes

### Later

Podcasts, newsletters, documents, voice notes, browser tabs, Slack, Discord, messages, email

Internally, everything is the same object: `Save`.

---

## 5. Capture experience (iOS)

Use an iOS share extension.

1. User sees something interesting
2. Taps Share
3. Chooses Keep
4. App displays `Saved ✓`
5. Share sheet closes

No folder selection. No title. No tags. No description. No waiting for processing.

Data received (depending on source): URL, text, image, video, source application, timestamp.

The backend immediately creates the save.

```json
{
  "url": "https://www.tiktok.com/@example/video/123",
  "source": "share_extension"
}
```

---

## 6. Save data model

```ts
interface Save {
  id: string
  userId: string
  source: string
  sourceUrl: string
  canonicalUrl: string
  contentType: string
  title?: string
  description?: string
  creatorName?: string
  creatorHandle?: string
  thumbnailUrl?: string
  rawText?: string
  transcript?: string
  extractedText?: string
  summary?: string
  topics: string[]
  entities: Entity[]
  keywords: string[]
  embedding?: number[]
  processingStatus: "saved" | "processing" | "ready" | "failed"
  sourceCreatedAt?: Date
  savedAt: Date
  createdAt: Date
}
```

Most of this metadata should remain invisible unless useful to the user.

---

## 7. Source adapter architecture

```ts
interface SourceAdapter {
  canHandle(url: string): boolean
  normalizeUrl(url: string): string
  getMetadata(url: string): Promise<Metadata>
}
```

Implement: TikTok, Instagram, YouTube, Twitter/X, Reddit, GitHub, Web.

Preferred ingestion hierarchy: official API / oEmbed → publicly available page metadata → content explicitly shared by the user → metadata-only save.

Do not make unauthorized scraping a critical dependency. Capture is more important than perfect enrichment.

---

## 8. Enrichment pipeline

Saving is synchronous. Understanding is asynchronous.

User shares → create save immediately → return “saved” → enqueue enrichment → detect source → normalize URL → retrieve permitted metadata → extract text → OCR if applicable → transcribe if permitted → topics → entities → short summary → embedding → related saves → update collections/interests → mark ready.

If enrichment fails: `processingStatus = failed`, but the original save remains.

---

## 9. Home screen

Keep home simple: search, recent saves, collections, resurfaced saves. Not an analytics dashboard.

---

## 10–11. Universal / hybrid search

Support exact, semantic, memory, and conceptual search. All should be capable of finding the same save.

Architecture: normalize query → keyword + semantic + entity matching + metadata filters → combine scores → rerank.

Initial ranking (tune later): 55% semantic, 25% keyword, 10% entity, 10% recency.

Postgres full-text + pgvector. No dedicated vector database until necessary.

---

## 12. Collections

Users should not need to manually create folders. Auto-identify collections (ai agents, startup ideas, coding, fashion, recipes, restaurants, travel, design, fitness). Users can still create, rename, pin, add/remove. One save can belong to multiple collections.

---

## 13. Related saves

Every save should show related content from different platforms and months. Implicit personal knowledge graph.

---

## 14. Ask your saves

Conversational retrieval, accessible from search — not the entire product. Answers must cite/link back to actual saves. The generated layer never replaces the underlying content.

---

## 15. Entity extraction

People, companies, apps, tools, frameworks, products, restaurants, locations, books, movies, artists, websites, repositories. Entity pages: “mentioned in 13 saves.”

---

## 16. Resurfacing

Not “remember this?” — “You’ve been saving browser-agent content again. You saved this 4 months ago.”

Signals: current interests, recent searches, recently saved topics, repeated entities, time, unfinished collections, similarity to new saves.

---

## 17. Weekly recap

One useful weekly recap. Avoid excessive notifications. Start with only the weekly recap.

---

## 18. Interest map

Optional, secondary. Do not feel like it is psychoanalyzing users.

---

## 19. Library exploration

Wikipedia-like exploration of the user’s own graph.

---

## 20. Screenshots

First-class saves: share → OCR → extract text → entities → classify → embedding.

---

## 21. Actions

Structured entities eventually provide actions (map, website, related saves, open GitHub, etc.).

---

## 22–24. Later: browser extension, shared collections, public collections

Do not launch with a social feed. Private by default. Public/shared collections are the viral loop (“save this collection”).

---

## 25. MVP (this iOS build)

**Build:** auth (later), iOS share extension, save URLs, detect source, basic metadata, screenshots, automatic topics, embeddings, semantic + keyword search, recent saves, save detail, related saves, basic collections.

**Support:** TikTok, Instagram, YouTube, X, Reddit, websites.

**Do not initially build:** social feed, followers, messaging, complex graph viz, dozens of integrations, complicated analytics, autonomous agents, large chat interface.

---

## 26. MVP screens

1. Onboarding  
2. Home  
3. Search  
4. Save detail  
5. Collection  

---

## 27. Native iOS stack

- Swift
- SwiftUI
- SwiftData (local source of truth on device for v1)
- iOS share extension (Swift)
- Later: backend (Supabase / Postgres / pgvector), Trigger.dev or Inngest, Upstash Redis

Do not use Expo, React Native, or a separate Android app until the iOS capture loop is proven.

---

## 40. Privacy

All saves private by default. Export / delete data, delete saves, delete account. Do not train models on private libraries without explicit permission.

> Your library belongs to you. Your saves are private by default.

---

## 44. North star

Not number of saves. **Weekly saves successfully revisited** (search, related, resurfacing, ask, share from library).

The magic moment: “holy shit, I forgot I saved this.”

---

## 52. Primary product risk

Will users share to this app instead of the platform’s native save button?

Share experience must be fast, reliable, frictionless, habit-forming: Share → Keep → Saved ✓ in ~1–2 seconds.

---

## 53. Moat

Not “we use AI to summarize videos.” The valuable asset is the user’s accumulated personal library and the relationships inside it. The product becomes more valuable the longer someone uses it.

---

## Build order

1. Foundation — SwiftData save model, home, detail  
2. Capture — iOS share extension, URL normalization, duplicates  
3. Enrichment — adapters, topics, entities, summaries, embeddings  
4. Retrieval — keyword + semantic hybrid search  
5. Organization — collections, related saves, entity pages  
6. Retention — worth revisiting, weekly recap  
7. Expansion — web, shared/public collections, ask, interest map  
