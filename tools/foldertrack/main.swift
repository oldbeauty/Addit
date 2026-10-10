import Foundation

// Checks `Addit/Models/FolderWatch.swift` as it ships. Each check states the
// rule it holds the model to; any failure is printed and the run exits
// non-zero. Run through ./check.sh.

nonisolated(unsafe) var failures = 0

func check(_ holds: Bool, _ rule: String, line: UInt = #line) {
    if holds {
        print("  ✓ \(rule)")
    } else {
        failures += 1
        print("  ✗ \(rule)  (main.swift:\(line))")
    }
}

func section(_ title: String) { print("\n\(title)") }

func folder(_ id: String, by person: String? = "Alex", me: Bool = false) -> FolderChild {
    FolderChild(id: id, name: id, kind: .folder, addedBy: person, addedByMe: me)
}

func track(_ id: String, by person: String? = "Alex", me: Bool = false) -> FolderChild {
    FolderChild(id: id, name: id, kind: .track, addedBy: person, addedByMe: me)
}

let goodMusic = WatchTarget(folderId: "GM", name: "Good Music")
let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

// MARK: - Baselines and what counts as new

section("Baselines and what counts as new")
var book = FolderWatchBook()
let baseline = book.record([folder("A"), folder("B"), track("t1")], in: goodMusic, at: at(0))
check(baseline.isEmpty, "a folder's first listing is its baseline: nothing already there is news")
check(book.snapshots["GM"]?.folders == 2 && book.snapshots["GM"]?.tracks == 1,
      "the baseline counts what the folder holds")

check(book.record([folder("A"), folder("B"), track("t1")], in: goodMusic, at: at(1)).isEmpty,
      "the same listing again is no news")

let added = book.record([folder("A"), folder("B"), folder("C"), track("t1")], in: goodMusic, at: at(2))
check(added.count == 1 && added[0].kind == .folder && added[0].count == 1
        && added[0].items.map(\.id) == ["C"] && added[0].addedBy == "Alex",
      "a subfolder that wasn't there before is one event, naming it and who added it")
check(added.first?.headline == "Alex added a folder to Good Music", "and reads as such")
check(added.first?.folderId == "GM" && added.first?.date == at(2),
      "the event points at the tracked folder and the check that found it")
check(book.snapshots["GM"]?.folders == 3, "the counts follow the latest listing")

check(book.record([folder("A")], in: goodMusic, at: at(3)).isEmpty,
      "children dropping out of a listing is not news")
check(book.snapshots["GM"]?.folders == 1, "though the counts say what's there now")
check(book.record([folder("A"), folder("B"), folder("C"), track("t1")], in: goodMusic, at: at(4)).isEmpty,
      "and coming back isn't news twice: the snapshot only grows")

check(book.record([], in: goodMusic, at: at(5)).isEmpty, "an empty listing (a share revoked) is no news")
check(book.record([folder("A"), folder("B"), folder("C"), track("t1")], in: goodMusic, at: at(6)).isEmpty,
      "nor is the folder's whole contents reappearing when it's restored")

let empty = WatchTarget(folderId: "E", name: "Empty")
check(book.record([], in: empty, at: at(0)).isEmpty && book.snapshots["E"] != nil,
      "an empty folder still takes a baseline")
check(book.record([folder("first")], in: empty, at: at(1)).count == 1,
      "so the first thing put in it is news, not swallowed as a late baseline")

let repeated = book.record([folder("D"), folder("D"), folder("A")], in: goodMusic, at: at(7))
check(repeated.count == 1 && repeated[0].count == 1 && repeated[0].items.count == 1,
      "an ID a listing repeats is one arrival")

// MARK: - Grouping and wording

section("Grouping and wording")
var grouped = FolderWatchBook()
_ = grouped.record([], in: goodMusic, at: at(0))
let mixed = grouped.record([
    track("song", me: true),
    folder("E"),
    folder("F", me: true),
    folder("G", by: nil),
    folder("H"),
    folder("I", by: "Sam"),
], in: goodMusic, at: at(1))
check(mixed.map(\.kind) == [.folder, .folder, .folder, .folder, .track],
      "folders come before tracks")
check(mixed.map(\.headline) == [
    "Alex added 2 folders to Good Music",
    "You added a folder to Good Music",
    "New folder in Good Music",
    "Sam added a folder to Good Music",
    "You added a track to Good Music",
], "one event per kind and person, in the order the listing met them")
check(mixed[0].items.map(\.id) == ["E", "H"], "each event names everything in it")
check(mixed[1].byMe && mixed[4].byMe && !mixed[0].byMe && !mixed[2].byMe,
      "your own additions are marked as yours; unattributed ones are not")

var many = FolderWatchBook()
_ = many.record([], in: goodMusic, at: at(0))
let flood = many.record((1...60).map { track("Track \($0)", by: "Alex") }, in: goodMusic, at: at(1))
check(flood.count == 1 && flood[0].count == 60 && flood[0].items.count == FolderWatchBook.itemsPerEvent,
      "an event names at most \(FolderWatchBook.itemsPerEvent) items and counts the rest")
check(flood.first?.items.prefix(3).map(\.name) == ["Track 1", "Track 2", "Track 3"],
      "items are sorted the way Finder sorts them (Track 2 before Track 10)")
check(flood.first?.headline == "Alex added 60 tracks to Good Music", "counts are in the wording")
let anonymous = FolderWatchEvent(
    id: UUID(), folderId: "R", folderName: "Rumours", kind: .track,
    items: [], count: 3, addedBy: nil, byMe: false, date: at(0)
)
check(anonymous.headline == "3 new tracks in Rumours", "no name, no attribution")

var faces = FolderWatchBook()
_ = faces.record([], in: goodMusic, at: at(0))
let pictured = faces.record([
    FolderChild(id: "P1", name: "P1", kind: .folder, addedBy: "Alex", addedByMe: false),
    FolderChild(id: "P2", name: "P2", kind: .folder, addedBy: "Alex", addedByMe: false,
                addedByPhoto: "https://example.com/alex=s64"),
], in: goodMusic, at: at(1))
check(pictured.first?.photo == "https://example.com/alex=s64",
      "an event carries the picture of whoever it's from, if any of its items had one")
let oldEvent = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","folderId":"GM","folderName":"Good Music","kind":"folder","items":[],"count":1,"addedBy":"Alex","byMe":false,"date":0}"#
check((try? JSONDecoder().decode(FolderWatchEvent.self, from: Data(oldEvent.utf8)))?.photo == nil,
      "an event saved before pictures were kept still opens, with none")

// MARK: - The event list

section("The event list")
var list = FolderWatchBook()
func event(_ name: String, at date: Date, byMe: Bool = false) -> FolderWatchEvent {
    FolderWatchEvent(id: UUID(), folderId: "GM", folderName: name, kind: .folder,
                     items: [], count: 1, addedBy: "Alex", byMe: byMe, date: date)
}
list.add([event("one", at: at(1))])
list.add([event("three", at: at(3)), event("three-b", at: at(3))])
list.add([event("two", at: at(2))])
check(list.events.map(\.folderName) == ["three", "three-b", "two", "one"],
      "newest first, even when an older check's events land later")
for minute in 10..<(10 + FolderWatchBook.eventLimit + 25) {
    list.add([event("bulk", at: at(Double(minute)))])
}
check(list.events.count == FolderWatchBook.eventLimit, "only the newest \(FolderWatchBook.eventLimit) are kept")
check(list.events.first?.date == at(Double(10 + FolderWatchBook.eventLimit + 24)),
      "and it's the oldest that go")

var unread = FolderWatchBook()
unread.add([event("old", at: at(1))])
unread.add([event("mine", at: at(5), byMe: true)])
unread.add([event("new", at: at(6))])
check(unread.unreadCount == 2,
      "never having opened the window, everything from others is unread, and your own never is")
unread.lastSeen = at(3)
check(unread.unreadCount == 1, "only what arrived since the window was last open is unread")
unread.lastSeen = at(6)
check(unread.unreadCount == 0, "the window being open clears them")

// MARK: - Pinned folders and pruning

section("Pinned folders and pruning")
var pins = FolderWatchBook()
check(pins.pin("GM", name: "Good Music", at: at(0)), "pinning a folder tracks it")
check(!pins.pin("GM", name: "Good Music", at: at(1)) && pins.pinned.count == 1, "pinning it twice doesn't")
_ = pins.record([folder("A")], in: goodMusic, at: at(0))
pins.unpin("GM", keepingSnapshot: true)
check(pins.pinned.isEmpty && pins.snapshots["GM"] != nil,
      "unpinning a folder that's also a library album keeps what it held")
_ = pins.pin("GM", name: "Good Music", at: at(2))
pins.unpin("GM", keepingSnapshot: false)
check(pins.snapshots["GM"] == nil, "otherwise it's forgotten, so tracking it again starts fresh")

var prune = FolderWatchBook()
let old = start.addingTimeInterval(-FolderWatchBook.snapshotRetention - 60)
_ = prune.record([], in: WatchTarget(folderId: "tracked-old", name: ""), at: old)
_ = prune.record([], in: WatchTarget(folderId: "untracked-old", name: ""), at: old)
_ = prune.record([], in: WatchTarget(folderId: "untracked-recent", name: ""), at: start)
prune.pruneSnapshots(tracking: ["tracked-old"], now: start)
check(Set(prune.snapshots.keys) == ["tracked-old", "untracked-recent"],
      "snapshots go once untracked and unlisted for \(Int(FolderWatchBook.snapshotRetention / 86_400)) days, not before")

// MARK: - The file

section("The file")
var saved = FolderWatchBook()
_ = saved.pin("GM", name: "Good Music", at: at(0))
_ = saved.record([folder("A"), track("t")], in: goodMusic, at: at(0))
saved.add(saved.record([folder("A"), folder("B"), track("t")], in: goodMusic, at: at(1)))
saved.lastChecked = at(1)
saved.lastSeen = at(0.5)
let data = try! JSONEncoder().encode(saved)
let restored = try! JSONDecoder().decode(FolderWatchBook.self, from: data)
check(restored == saved, "a book survives the round trip exactly")
let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
check(json?["version"] as? Int == FolderWatchBook.version, "the file says which version wrote it")
check((try? JSONDecoder().decode(FolderWatchBook.self, from: Data("{}".utf8))) == FolderWatchBook(),
      "a file missing every field opens as an empty book")
let partial = try? JSONDecoder().decode(
    FolderWatchBook.self,
    from: Data(#"{"version":1,"pinned":[{"id":"GM","name":"Good Music","pinnedAt":0,"isMissing":false}]}"#.utf8)
)
check(partial?.pinned.first?.name == "Good Music" && partial?.events.isEmpty == true,
      "a file from before a field existed keeps what it has")

// MARK: - Listing batches

section("Listing batches")
var queue = ListingQueue((1...70).map { "f\($0)" }, batchSize: 30)
var sizes: [Int] = []
while let batch = queue.next() { sizes.append(batch.count) }
check(sizes == [30, 30, 10], "folders are listed batchSize at a time")
check(ListingQueue([], batchSize: 30).unlistable.isEmpty, "nothing to list is nothing to do")
var nothing = ListingQueue([], batchSize: 30)
check(nothing.next() == nil, "and asks for nothing")

// A drive that won't list "gone" folders, and turns down any query over 12.
let ids = (1...64).map { $0 % 17 == 0 ? "gone\($0)" : "ok\($0)" }
var drive = ListingQueue(ids, batchSize: 30)
var listed: [String] = []
var requests = 0
while let batch = drive.next() {
    requests += 1
    if batch.count > 12 || batch.contains(where: { $0.hasPrefix("gone") }) {
        drive.reject(batch)
    } else {
        listed += batch
    }
    if requests > 500 { break }
}
check(requests <= 500, "a check that keeps being turned down still ends")
check(Set(listed) == Set(ids.filter { $0.hasPrefix("ok") }) && listed.count == Set(listed).count,
      "every folder the drive can list is listed exactly once")
check(drive.unlistable == Set(ids.filter { $0.hasPrefix("gone") }),
      "and only the folders it can't are given up on")
print("    (\(ids.count) folders, \(requests) requests)")

var single = ListingQueue(["x", "y"], batchSize: 1)
let first = single.next()!
single.reject(first)
check(single.unlistable == ["x"] && single.next() == ["y"], "a folder alone that's turned down is given up on")

// MARK: - Readouts

section("Readouts")
check(WatchReadout.age(of: at(0), now: at(0.5)) == "NOW", "under a minute is now")
check(WatchReadout.age(of: at(0), now: at(5)) == "5M AGO", "minutes")
check(WatchReadout.age(of: at(0), now: at(3 * 60 + 10)) == "3H AGO", "hours")
check(WatchReadout.age(of: at(0), now: at(2 * 24 * 60 + 1)) == "2D AGO", "days")
let dated = WatchReadout.age(of: at(0), now: at(30 * 24 * 60))
check(!dated.contains("AGO") && dated == dated.uppercased() && !dated.isEmpty, "then a date (\(dated))")
check(WatchReadout.age(of: at(10), now: at(0)) == "NOW", "a clock that's behind doesn't go negative")
check(WatchReadout.contents(folders: 12, tracks: 3) == "12 folders · 3 tracks", "contents, both kinds")
check(WatchReadout.contents(folders: 1, tracks: 0) == "1 folder", "only the kinds there are")
check(WatchReadout.contents(folders: 0, tracks: 0) == "Empty", "and an empty folder says so")

print(failures == 0 ? "\n✓ all checks hold" : "\n✗ \(failures) failed")
exit(failures == 0 ? 0 : 1)
