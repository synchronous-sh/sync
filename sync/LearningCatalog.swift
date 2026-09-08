import Foundation
import SwiftUI
import SwiftData

struct LearningPath: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var description: String
    var symbol: String
    var lessons: [LearningLesson]
}

struct LearningLesson: Identifiable, Hashable, Codable {
    var id: String { title }
    var title: String
    var core: String
    var mechanism: String
    var application: String
}

struct CourseShelf: Identifiable {
    var id: String { title }
    var title: String
    var items: [CourseCard]
}

struct CourseCard: Identifiable, Hashable {
    var id: String { "\(pathID)-\(title)" }
    var pathID: String
    var title: String
    var subtitle: String
    var progress: Double?
}

enum LearningProgress {
    private static let key = "completedLessonIDs"
    private static let pageKey = "lessonResumePage"
    private static let quizKey = "lessonResumeQuiz"
    private static var store: UserDefaults { AppGroup.defaults ?? .standard }

    static func completed() -> Set<String> {
        Set(store.stringArray(forKey: key) ?? UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isComplete(pathID: String, lesson: String) -> Bool {
        completed().contains("\(pathID):\(lesson)")
    }

    static func toggle(pathID: String, lesson: String) {
        var items = completed()
        let token = "\(pathID):\(lesson)"
        if items.contains(token) { items.remove(token) } else { items.insert(token) }
        store.set(Array(items), forKey: key)
        UserDefaults.standard.set(Array(items), forKey: key)
        if items.contains(token) { clearResume(pathID: pathID, lesson: lesson) }
    }

    static func fraction(for path: LearningPath) -> Double {
        guard !path.lessons.isEmpty else { return 0 }
        let done = path.lessons.filter { isComplete(pathID: path.id, lesson: $0.title) }.count
        return Double(done) / Double(path.lessons.count)
    }

    static func resumePage(pathID: String, lesson: String) -> Int {
        let map = store.dictionary(forKey: pageKey) as? [String: Int] ?? [:]
        return map["\(pathID):\(lesson)"] ?? 0
    }

    static func resumeQuiz(pathID: String, lesson: String) -> [Int] {
        (store.dictionary(forKey: quizKey)?["\(pathID):\(lesson)"] as? [Int]) ?? []
    }

    static func saveResume(pathID: String, lesson: String, step: Int, quizAnswers: [Int]) {
        let token = "\(pathID):\(lesson)"
        var pages = store.dictionary(forKey: pageKey) as? [String: Int] ?? [:]
        pages[token] = max(0, step)
        store.set(pages, forKey: pageKey)
        var quizzes = store.dictionary(forKey: quizKey) ?? [:]
        quizzes[token] = quizAnswers
        store.set(quizzes, forKey: quizKey)
    }

    private static let openedKey = "courseLastOpened"

    static func opened(_ pathID: String) {
        var map = store.dictionary(forKey: openedKey) as? [String: Double] ?? [:]
        map[pathID] = Date().timeIntervalSince1970
        store.set(map, forKey: openedKey)
        UserDefaults.standard.set(map, forKey: openedKey)
    }

    static func openedAt(_ pathID: String) -> Date? {
        let map = store.dictionary(forKey: openedKey) as? [String: Double]
            ?? UserDefaults.standard.dictionary(forKey: openedKey) as? [String: Double]
            ?? [:]
        guard let value = map[pathID] else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func hasStarted(_ path: LearningPath) -> Bool {
        if openedAt(path.id) != nil { return true }
        if fraction(for: path) > 0 { return true }
        return path.lessons.contains {
            resumePage(pathID: path.id, lesson: $0.title) > 0 || isComplete(pathID: path.id, lesson: $0.title)
        }
    }

    static func clearResume(pathID: String, lesson: String) {
        let token = "\(pathID):\(lesson)"
        var pages = store.dictionary(forKey: pageKey) as? [String: Int] ?? [:]
        pages.removeValue(forKey: token)
        store.set(pages, forKey: pageKey)
        var quizzes = store.dictionary(forKey: quizKey) ?? [:]
        quizzes.removeValue(forKey: token)
        store.set(quizzes, forKey: quizKey)
    }
}

enum LearningCatalog {
    static func path(id: String) -> LearningPath? {
        paths.first { $0.id == id }
    }

    static var paths: [LearningPath] {
        var seen = Set<String>()
        var out: [LearningPath] = []
        for path in officialPaths + CourseStudio.generated {
            if seen.insert(path.id).inserted { out.append(path) }
        }
        return out
    }

    @MainActor
    static func liveShelves(saves: [SaveItem]) -> [CourseShelf] {
        TasteEngine.ingest(saves)
        let recents = recentsCards()
        let recentCourses = Array(recents.filter { !$0.pathID.hasPrefix("book-") }.prefix(4))
        let recentBooks = Array(recents.filter { $0.pathID.hasPrefix("book-") }.prefix(4))
        let personal = CourseStudio.generated.map { path in
            CourseCard(
                pathID: path.id,
                title: path.title,
                subtitle: path.description,
                progress: LearningProgress.fraction(for: path)
            )
        }
        let ranked = TasteEngine.rankCourses(courseCards)
        var forYou: [CourseCard] = []
        var used = Set<String>()
        for item in personal + ranked {
            if used.insert(item.pathID).inserted { forYou.append(item) }
            if forYou.count == 6 { break }
        }
        var out: [CourseShelf] = []
        if !recentCourses.isEmpty {
            out.append(CourseShelf(title: "Recent courses", items: recentCourses))
        }
        if !recentBooks.isEmpty {
            out.append(CourseShelf(title: "Recent books", items: recentBooks))
        }
        if !forYou.isEmpty {
            out.append(CourseShelf(title: "For you", items: forYou))
        }
        for shelf in shelves where shelf.title != "Recents" && shelf.title != "Recent courses" && shelf.title != "Recent books" && shelf.title != "Recommended" {
            out.append(shelf)
        }
        let recentIDs = Set(recents.map(\.pathID))
        let recommended = ranked.filter { !recentIDs.contains($0.pathID) }.prefix(3)
        if !recommended.isEmpty {
            out.insert(CourseShelf(title: "Recommended", items: Array(recommended)), at: min(out.count, recentCourses.isEmpty && recentBooks.isEmpty ? 0 : (recentBooks.isEmpty || recentCourses.isEmpty ? 1 : 2)))
        }
        return out
    }

    private static func recentsCards() -> [CourseCard] {
        paths.compactMap { path -> (Date, CourseCard)? in
            guard LearningProgress.hasStarted(path) else { return nil }
            let fraction = LearningProgress.fraction(for: path)
            let next = path.lessons.first { !LearningProgress.isComplete(pathID: path.id, lesson: $0.title) }
            let title = courseCards.first(where: { $0.pathID == path.id })?.title ?? path.title
            let subtitle = fraction >= 1
                ? "Completed"
                : "Continue with \(next?.title ?? "lessons")"
            let stamp = LearningProgress.openedAt(path.id) ?? Date.distantPast
            return (stamp, CourseCard(pathID: path.id, title: title, subtitle: subtitle, progress: fraction == 0 ? 0.04 : fraction))
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
    }

    static let officialPaths: [LearningPath] = [
        path("ai", "Artificial Intelligence", "Understand how modern AI systems work.", "brain", [
            lesson("What is AI?", "Software designed to perform tasks that normally need human judgment.", "It maps inputs to outputs using rules or patterns learned from examples.", "Recommenders rank items that are most relevant to a person."),
            lesson("Machine Learning", "Systems improve from data instead of only hand-written rules.", "Training reduces the gap between predictions and known answers.", "A spam filter learns from messages labeled spam or safe."),
            lesson("Neural Networks", "Layered models that learn useful representations from examples.", "Weights change so later layers recognize more complex patterns.", "Vision models go from edges to shapes to objects."),
            lesson("Transformers", "Each part of a sequence can attend to the parts that matter most.", "Attention assigns changing importance based on context.", "The model can resolve what “it” refers to from earlier words."),
            lesson("Large Language Models", "Models that predict and generate language from vast text collections.", "They produce one token at a time, conditioned on prior context.", "They can summarize, translate, explain, and draft from instructions."),
            lesson("AI Agents", "A model plus goals, memory, and tools for multi-step work.", "The agent plans, acts, checks, and revises until it stops.", "A research agent can search, compare evidence, and write a report.")
        ]),
        path("finance", "Finance", "Understand how money and markets move.", "chart.line.uptrend.xyaxis", [
            lesson("Money", "A shared medium of exchange, unit of account, and store of value.", "Trust and scarcity let money coordinate trade across time.", "Prices in one currency make unlike products comparable."),
            lesson("Banks", "They connect savers who supply capital with borrowers who need it.", "Short-term deposits become longer-term loans, with liquidity risk.", "A mortgage turns pooled deposits into long-term housing credit."),
            lesson("Stocks", "A share is a fractional ownership claim on a company.", "Price reflects expected cash flows, risk, and what buyers will pay today.", "Owners can benefit from dividends and growth in value."),
            lesson("Bonds", "A loan that promises scheduled interest and principal.", "Prices generally move opposite to market interest rates.", "Governments issue bonds to finance projects over long periods."),
            lesson("Interest Rates", "The price paid to use money over time.", "Rates influence borrowing, saving, asset values, and demand.", "Lower mortgage rates can support a larger loan for the same payment."),
            lesson("Valuation", "An estimate of what an asset is worth given cash and risk.", "Future cash is discounted because money today is more useful.", "Investors compare market price with estimated intrinsic value."),
            lesson("Risk", "Outcomes can differ materially from what was expected.", "Diversification reduces single-source fragility, not all uncertainty.", "A basket of companies is less fragile than one stock."),
            lesson("Options", "Contracts that give the right, not the obligation, to buy or sell.", "Value depends on the underlying price, time, and expected movement.", "A call can hedge or speculate on a rise without owning the asset.")
        ]),
        path("history", "World History", "See how the modern world took shape.", "globe.europe.africa", [
            lesson("Ancient Civilizations", "Early states organized surplus, writing, and law.", "Agriculture supported specialists, cities, and hierarchy.", "River valleys concentrated food, trade, and political power."),
            lesson("Greece", "City-states experimented with citizenship, reason, and art.", "Colonies and seas spread language and political ideas.", "Later republics borrowed Greek ideas of debate and law."),
            lesson("Rome", "A republic became an empire that unified a huge territory.", "Roads, law, and citizenship bound diverse peoples together.", "Roman law still shapes legal language and institutions."),
            lesson("Medieval World", "Faith, land, and trade structured life after Rome.", "Networks of obligation and towns rebuilt economic life.", "Universities and trade routes carried knowledge across regions."),
            lesson("Industrial Revolution", "Machines and fossil energy multiplied output.", "Factories, cities, and capital markets remade daily work.", "Mass production changed prices, labor, and political power."),
            lesson("World Wars", "Industrial states fought at unprecedented scale.", "Total war mobilized economies, science, and civilians.", "The aftermath redrew borders and created new institutions.")
        ]),
        path("science", "Science", "Learn how evidence explains the natural world.", "atom", [
            lesson("Scientific Method", "Claims earn trust through testable evidence.", "Hypotheses are checked against observation and revision.", "A well-designed experiment can falsify a tempting idea."),
            lesson("Matter", "Stuff is made of particles that combine in patterns.", "Atoms and molecules explain materials and chemistry.", "Water’s structure explains why ice floats."),
            lesson("Energy", "Energy is conserved and changes form.", "Work, heat, and fields move energy through systems.", "A battery stores chemical energy for later electrical work."),
            lesson("Life", "Living systems copy information and use energy.", "Cells, genes, and selection explain diversity.", "Photosynthesis captures sunlight into chemical stores."),
            lesson("Earth Systems", "Atmosphere, oceans, and rock interact as one system.", "Feedbacks can amplify or dampen change.", "Ice cores record past climate in trapped air."),
            lesson("The Universe", "Space, time, and matter have a shared history.", "Gravity shapes galaxies, stars, and orbits.", "Light from distant objects is a record of the past.")
        ]),
        path("business", "Business", "Understand how organizations create lasting value.", "briefcase", [
            lesson("Customers", "Value starts with a job someone needs done.", "Demand appears when a product is better than the next option.", "Interviews and usage data reveal what people actually pay for."),
            lesson("Business Models", "How a company creates, delivers, and captures value.", "Revenue, cost, and incentives have to line up.", "Subscriptions trade a lower first payment for recurring cash."),
            lesson("Operations", "Reliable delivery is a product of process.", "Throughput, quality, and inventory trade off against each other.", "A kitchen’s mise en place is an operations system."),
            lesson("Strategy", "Choosing where to play and how to win.", "Advantage comes from activities rivals find hard to copy.", "A focused brand can beat a broader but thinner competitor."),
            lesson("Growth", "Scale works when unit economics stay healthy.", "Distribution and retention often matter more than novelty.", "A product that users share can grow without matching ad spend."),
            lesson("Leadership", "People coordinate when goals and feedback are clear.", "Incentives and culture decide what happens when nobody is watching.", "Good managers remove blockers and raise decision quality.")
        ]),
        path("technology", "Technology", "Understand the systems shaping modern life.", "cpu", [
            lesson("Computing", "Machines follow instructions over data.", "Hardware executes; software specifies the steps.", "A phone is a general computer with radios and sensors."),
            lesson("Networks", "Devices share information across links.", "Protocols let unlike machines agree on format and routing.", "The internet is a network of networks with no single owner."),
            lesson("Software", "Programs encode procedures that can be copied cheaply.", "Abstraction hides complexity behind interfaces.", "An API lets one product reuse another’s capability."),
            lesson("Security", "Trust on a network has to be earned and defended.", "Authentication, encryption, and least privilege limit damage.", "A password manager reduces reuse across sites."),
            lesson("Robotics", "Machines that sense, decide, and act in the physical world.", "Control loops close the gap between intent and motion.", "A warehouse robot follows maps, sensors, and task queues."),
            lesson("The Future", "New tools change what people can automate.", "Capability grows when compute, data, and interfaces improve together.", "Assistants will take on more multi-step work over time.")
        ]),
        path("psychology", "Psychology", "Explore the science of thought and behavior.", "heart.text.square", [
            lesson("Perception", "The brain constructs a usable model of the world.", "Attention and prior belief shape what we notice.", "Optical illusions reveal the shortcuts perception uses."),
            lesson("Memory", "Memory is reconstructed, not replayed like tape.", "Encoding, storage, and retrieval can each fail.", "Sleep and spaced practice strengthen useful traces."),
            lesson("Learning", "Behavior changes with experience and feedback.", "Reinforcement and association update future choices.", "Practice with correction beats passive review."),
            lesson("Emotion", "Feelings coordinate attention, body, and action.", "Appraisal of a situation often precedes the feeling.", "Naming an emotion can reduce its intensity."),
            lesson("Habits", "Repeated context-response pairs become automatic.", "Cues trigger routines that used to need willpower.", "Changing the environment is often easier than forcing will."),
            lesson("Decision Making", "People use shortcuts under uncertainty.", "Framing and defaults can swing choices.", "A checklist can beat a tired snap judgment.")
        ]),
        path("space", "Space", "Explore planets, stars, and the wider universe.", "sparkles", [
            lesson("Our Solar System", "Planets formed from a disk around the young sun.", "Distance from the sun shaped ice, rock, and gas worlds.", "Moons and rings are leftover architecture of that disk."),
            lesson("Stars", "Stars fuse lighter elements into heavier ones.", "Mass decides lifetime, brightness, and ending.", "Heavy elements in your body were made in earlier stars."),
            lesson("Galaxies", "Gravity binds stars, gas, and dark matter together.", "Collisions and accretion grow larger structures.", "The Milky Way is one galaxy among billions."),
            lesson("Gravity", "Mass curves spacetime and guides motion.", "Orbits are free-fall paths that miss the surface.", "Tides are the leftover difference in gravitational pull."),
            lesson("Spaceflight", "Rockets trade propellant for speed.", "Orbital mechanics, not just thrust, get you somewhere.", "A gravity assist can steal motion from a planet."),
            lesson("Cosmology", "The universe is expanding from a hot, dense start.", "Light stretch and leftover radiation record that history.", "Dark energy appears to accelerate the expansion.")
        ]),
        path("cooking", "Cooking", "Learn the science and craft behind great food.", "fork.knife", [
            lesson("Heat", "Cooking is controlled energy transfer.", "Conduction, convection, and radiation cook differently.", "A sear builds flavor while the center stays tender."),
            lesson("Seasoning", "Salt, acid, fat, and heat shape taste.", "Seasoning throughout cooking beats a last-second dump.", "A squeeze of lemon can wake up a heavy sauce."),
            lesson("Texture", "Crisp, tender, and creamy come from structure.", "Water, protein, and starch set mouthfeel.", "Resting meat lets juices redistribute."),
            lesson("Baking", "Ratios and temperature decide rise and crumb.", "Gluten and leaveners build structure you cannot easily undo.", "Weighing ingredients makes results repeatable."),
            lesson("Sauces", "A sauce concentrates flavor and moisture.", "Emulsions and reductions bind fat and water.", "Pan drippings plus stock become a quick gravy."),
            lesson("Timing", "Doneness is a window, not a single number.", "Mise en place keeps the window from closing.", "Carryover heat continues cooking off the stove.")
        ]),
        path("sports", "Sports Science", "Understand performance, movement, and recovery.", "figure.run", [
            lesson("Movement", "Skill is coordinated force through a range of motion.", "Joints, timing, and balance decide efficiency.", "A better pattern often beats more effort."),
            lesson("Strength", "Muscles adapt to the loads they repeatedly meet.", "Progressive overload with recovery grows capacity.", "Compound lifts train many muscles in one pattern."),
            lesson("Endurance", "The body delivers oxygen and fuel over time.", "Aerobic base supports longer, repeatable work.", "Easy volume plus some intensity is a common mix."),
            lesson("Skill", "Repetition with attention builds automatic technique.", "Feedback closes the gap between intent and result.", "Slow, correct reps beat sloppy speed."),
            lesson("Recovery", "Adaptation happens after the work, not during it.", "Sleep, food, and rest restore the systems you stressed.", "An extra easy day can raise the quality of the next hard one."),
            lesson("Teamwork", "Shared timing multiplies individual skill.", "Roles and communication reduce chaos under pressure.", "A set play is a coordination protocol.")
        ]),
        path("economics", "Economics", "See how incentives shape markets and society.", "scalemass", [
            lesson("Scarcity", "Wants exceed what time and resources can provide.", "Every choice has an opportunity cost.", "A budget is a map of tradeoffs."),
            lesson("Supply & Demand", "Prices coordinate buyers and sellers.", "When price rises, some demand falls and some supply appears.", "A shortage is a price that is not allowed to move."),
            lesson("Inflation", "A broad, sustained rise in the price level.", "Too much spending relative to goods, or rising costs, can drive it.", "Wages that lag prices reduce real purchasing power."),
            lesson("Labor", "Work is traded in a market with search and skills.", "Productivity and bargaining power influence pay.", "Training can raise the value of an hour of work."),
            lesson("Trade", "Specializing and exchanging can raise total output.", "Comparative advantage, not absolute skill, is enough.", "A country can import what others make more cheaply."),
            lesson("Growth", "More output per person over time.", "Ideas, capital, and institutions compound.", "A small yearly gain becomes huge across decades.")
        ]),
        path("design", "Design", "Learn to make useful, clear, and beautiful things.", "square.and.pencil", [
            lesson("Hierarchy", "Not everything can be equally important.", "Size, weight, and space guide the eye.", "A clear headline tells people where to start."),
            lesson("Typography", "Type is the voice of the interface.", "Size, leading, and measure decide comfort.", "One strong family beats five competing fonts."),
            lesson("Color", "Color carries meaning and emotion.", "Contrast keeps text readable; restraint keeps focus.", "A single accent can do more than a rainbow."),
            lesson("Interaction", "People learn by doing, not reading a manual.", "Affordances and feedback show what is possible.", "A button should look pressable and then respond."),
            lesson("Research", "Guesses get cheaper when you watch real use.", "Interviews and tests reveal friction you cannot feel yourself.", "Five users can expose the same broken step."),
            lesson("Systems", "Reusable parts keep products coherent as they grow.", "Tokens and components encode decisions once.", "A design system is documented agreement.")
        ]),
        path("book-habits", "Atomic Habits", "How small, repeatable actions compound into identity and results.", "book", [
            lesson("The 1% Compound", "Tiny improvements stack because they repeat.", "A slightly better daily loop grows exponentially over months.", "A two-minute reading habit beats a rare three-hour binge."),
            lesson("Identity First", "Habits stick when they prove who you are becoming.", "Each repetition is a vote for a new identity.", "“I am a runner” survives a missed long run better than a calorie target."),
            lesson("Cue, Craving, Response, Reward", "Every habit is a four-step loop.", "The environment starts the loop; the reward teaches the brain to repeat it.", "Putting running shoes by the door raises the odds you leave the house."),
            lesson("Make It Obvious and Easy", "Friction decides more than motivation.", "Reduce steps for good loops and add steps for bad ones.", "A fruit bowl on the counter beats willpower at 10 p.m."),
            lesson("Never Miss Twice", "A miss is data; a streak of misses is a new habit.", "Recovery is part of the system, not a moral reset.", "Skip one workout, then do a ten-minute version the next day.")
        ]),
        path("book-thinking", "Thinking, Fast and Slow", "Two modes of mind: fast intuition and slower, effortful reasoning.", "book", [
            lesson("System 1 and System 2", "The mind has a fast pattern-matcher and a slow checker.", "System 1 proposes; System 2 endorses, rejects, or never wakes up.", "You finish a familiar drive with almost no memory of the turns."),
            lesson("Heuristics", "Shortcuts keep us moving, and they also misfire.", "Availability, representativeness, and anchoring fill gaps in evidence.", "A vivid plane crash can outweigh years of safe statistics."),
            lesson("Overconfidence", "Feeling sure is not the same as being right.", "Coherent stories feel true even when the sample is tiny.", "A confident forecast still needs a base rate."),
            lesson("Prospects and Loss", "Losses sting more than equal gains please.", "Framing the same numbers as loss or gain flips the choice.", "A “90% survival” treatment sounds safer than “10% mortality.”"),
            lesson("When to Slow Down", "Effortful thought is expensive, so spend it on the expensive mistakes.", "Noise, high stakes, and reversible vs irreversible decisions are the cues.", "Sleep on a career move; don’t overthink which checkout line.")
        ]),
        path("book-money", "The Psychology of Money", "Behavior with money often beats a clever spreadsheet.", "book", [
            lesson("Reasonable Beats Perfect", "A plan you can live with beats an optimal plan you abandon.", "Survival and consistency compound more than peak returns.", "A boring index habit can outrun a brilliant but panicked trader."),
            lesson("Luck and Risk", "Outcomes mix skill with chance.", "Copying a winner without the risk they took is a category error.", "One viral success does not prove a method."),
            lesson("Enough", "The hardest number is the one that lets you stop racing.", "Goalposts move unless you name them.", "A raise that only funds a bigger comparison is not enough."),
            lesson("Room for Error", "The future is a range, not a point estimate.", "Cash, time, and optionality are how you absorb surprise.", "Avoiding ruin matters more than squeezing the last percent."),
            lesson("Tails and Time", "A few outcomes dominate lifetime results.", "Staying in the game lets the rare good years show up.", "Missing the market’s best weeks is how “safe” cash underperforms.")
        ]),
        path("book-lean", "The Lean Startup", "Treat a new product like an experiment, not a miniature corporation.", "book", [
            lesson("Build-Measure-Learn", "The unit of progress is validated learning.", "Ship a smallest test, measure behavior, then keep or kill the idea.", "A landing page with a waitlist can beat six months of silent building."),
            lesson("MVP", "The first version exists to answer a question.", "Strip features until only the risky assumption remains.", "A concierge version of the service can fake the backend."),
            lesson("Innovation Accounting", "Vanity metrics hide whether you are learning.", "Cohorts, conversion, and actionable counts replace total signups.", "Weekly activation of new users beats a rising follower count."),
            lesson("Pivot or Persevere", "A pivot changes strategy without throwing away the engine of learning.", "You pivot when the tests keep failing the same assumption.", "Same customers, new problem — or same problem, new channel."),
            lesson("Small Batches", "Shorter cycles reduce waste.", "Andon-style stops prevent a defect from multiplying.", "A daily deploy finds a bad copy change before it hits everyone.")
        ]),
        path("book-design", "The Design of Everyday Things", "Good design makes the right action visible and the wrong one hard.", "book", [
            lesson("Affordances and Signifiers", "Objects should advertise what you can do with them.", "Signifiers are the clues; affordances are the actual possibilities.", "A handle says pull; a plate says push."),
            lesson("Mapping", "Controls should spatially match what they change.", "Natural mapping cuts memory load.", "Stove knobs in the same layout as the burners."),
            lesson("Feedback", "Every action needs a timely, intelligible response.", "Silence looks like failure; delay looks like a freeze.", "A spinner that names the step beats a blank screen."),
            lesson("Constraints", "Limits prevent errors before they happen.", "Physical, cultural, and logical constraints shrink the search space.", "A USB-C cable that only fits one way."),
            lesson("Knowledge in the World", "Don’t make people memorize what the object can show.", "Labels, structure, and defaults carry the knowledge.", "An oven that shows the current mode instead of a secret code.")
        ]),
        path("book-sapiens", "Sapiens", "How shared stories let large groups cooperate.", "book", [
            lesson("Cognitive Revolution", "Flexible language let us gossip, plan, and invent fictions.", "Shared myths scale trust beyond a Dunbar-sized tribe.", "Money, nations, and limited companies only work if enough people believe."),
            lesson("Agriculture", "Farming raised calories and also raised toil and hierarchy.", "Surplus feeds specialists; specialists build states.", "A grain store needs guards, records, and someone in charge."),
            lesson("Unification", "Empires, money, and religions stitch strangers into one game.", "Standard rules lower the cost of trade and war.", "A common coin and a common law make a market."),
            lesson("Scientific Revolution", "Admitting ignorance became a method.", "Observation plus institutions (labs, journals) compound knowledge.", "Vaccines and engines are social technologies as much as gadgets."),
            lesson("The Modern Bargain", "Comfort and power arrived with new risks.", "Consumer culture and industrial energy rewrite daily life.", "A supermarket is a miracle that still depends on fragile supply chains.")
        ]),
        path("book-range", "Range", "Breadth can beat early hyperspecialization in messy domains.", "book", [
            lesson("Kind vs Wicked Worlds", "Chess has kind feedback; careers often do not.", "When rules are hidden, sampling many fields helps.", "A generalist doctor notices a pattern a narrow specialist might skip."),
            lesson("Late Specialization", "Many elite paths include a sampling period.", "Match quality matters more than starting young.", "Switching majors can be information, not failure."),
            lesson("Analogical Thinking", "Distant domains supply fresh models.", "You import a structure, not a costume.", "A jazz habit of improvisation can help a product team recover live."),
            lesson("The Outside View", "Compare to a class of similar cases, not your unique story.", "Base rates puncture narrative overconfidence.", "Most startups fail; plan as if you might be typical."),
            lesson("Interleaving", "Mixing problems teaches discrimination.", "Blocked practice feels fluent and transfers less.", "Study two related concepts in one sitting instead of one for a week.")
        ]),
        path("book-deep-work", "Deep Work", "Focus is a skill and a scarce economic asset.", "book", [
            lesson("Attention Residue", "Task-switching leaves a trail that taxes the next task.", "Notifications keep residue high all day.", "A closed laptop during a writing block is a design choice."),
            lesson("Depth Philosophy", "Monastic, bimodal, rhythmic, and journalistic are different bets.", "Pick a cadence your job can actually support.", "Two ninety-minute blocks before noon can beat an “open” afternoon."),
            lesson("Rituals", "Place, time, and shutdown cues train the brain.", "A shutdown complete phrase closes open loops.", "Write tomorrow’s first sentence before you leave."),
            lesson("Embrace Boredom", "The mind that cannot be bored cannot concentrate.", "Schedule shallow work so it does not invade deep time.", "Walk without a podcast when you need a hard problem to cook."),
            lesson("Quit Social by Default", "Tools should earn their place with a positive case.", "Any network that fragments attention needs a job description.", "Batch messages twice a day instead of living in the inbox.")
        ]),
        path("book-investor", "The Intelligent Investor", "Investing is a temperament plus a margin of safety.", "book", [
            lesson("Mr. Market", "The market is a moody partner, not a teacher.", "Price is an offer; value is an estimate.", "A crash is a sale if you already know what you own."),
            lesson("Margin of Safety", "Buy so that being a little wrong is not fatal.", "Conservative assumptions beat precise fantasies.", "A cheap, understandable business beats a story stock."),
            lesson("Investor vs Speculator", "Investors own a claim on cash flows; speculators own a price move.", "Time horizon and process separate the two.", "Checking a quote every hour is usually speculation."),
            lesson("Defensive vs Enterprising", "Most people should be defensive: diversified, low-cost, patient.", "Enterprising work is a job, not a hobby.", "If you will not read filings, do not pick stocks."),
            lesson("Costs and Behavior", "Fees and panic are the silent compounding killers.", "Automation and rules beat mood.", "A target-date or index plan you will not abandon is a strategy.")
        ]),
        path("book-influence", "Influence", "People say yes through predictable social levers.", "book", [
            lesson("Reciprocity", "Uninvited gifts create a debt.", "The concession after a large ask is a second gift.", "A free sample can make a paid upgrade feel like returning a favor."),
            lesson("Commitment and Consistency", "We align later acts with earlier labels.", "A small written yes pulls a larger one.", "A public goal post makes backing out socially expensive."),
            lesson("Social Proof", "Uncertainty makes us copy the crowd.", "The more similar the crowd, the stronger the pull.", "Empty restaurants stay empty; laugh tracks still work."),
            lesson("Authority and Liking", "Titles, uniforms, and attractiveness short-circuit scrutiny.", "We help people who are like us and who flatter us.", "A lab coat can make bad advice sound medical."),
            lesson("Scarcity", "Loss of access feels like loss of value.", "Deadlines and “only a few left” raise arousal, not analysis.", "Sleep on a limited-time offer that is not actually limited.")
        ])
    ]

    static let shelves: [CourseShelf] = [
        CourseShelf(title: "Recent courses", items: [
            card("finance", "Finance", "Continue with Banks", 0.18),
            card("history", "World History", "Continue with Greece", 0.12),
            card("technology", "Technology", "Continue with Networks", 0.16)
        ]),
        CourseShelf(title: "Recommended", items: [
            card("ai", "Artificial Intelligence", "Models, transformers, and agents"),
            card("psychology", "Psychology", "Memory, emotion, and decisions"),
            card("economics", "Economics", "Incentives, markets, and growth")
        ]),
        CourseShelf(title: "New", items: [
            card("science", "Science", "Evidence and the natural world"),
            card("space", "Space", "From planets to cosmology"),
            card("design", "Design", "Clear and useful systems")
        ]),
        CourseShelf(title: "Book courses", items: [
            card("book-habits", "Atomic Habits", "Tiny changes that compound"),
            card("book-thinking", "Thinking, Fast and Slow", "Intuition and its traps"),
            card("book-money", "The Psychology of Money", "Behavior over spreadsheets"),
            card("book-lean", "The Lean Startup", "Learn with experiments"),
            card("book-design", "The Design of Everyday Things", "Why objects confuse us"),
            card("book-sapiens", "Sapiens", "Myths that scale cooperation"),
            card("book-range", "Range", "Why generalists still win"),
            card("book-deep-work", "Deep Work", "Focus as a skill"),
            card("book-investor", "The Intelligent Investor", "Temperament and safety"),
            card("book-influence", "Influence", "The levers of yes")
        ]),
        CourseShelf(title: "Business", items: [
            card("business", "Business Strategy", "Customers to leadership"),
            card("finance", "Finance Essentials", "Money, markets, and risk"),
            card("economics", "Market Economics", "Supply, demand, and trade")
        ]),
        CourseShelf(title: "Technology", items: [
            card("technology", "Computing & Software", "Networks, security, and robotics"),
            card("ai", "Applied AI", "Machine learning to agents"),
            card("design", "Digital Product Design", "Research and interaction")
        ]),
        CourseShelf(title: "AI", items: [
            card("ai", "AI Foundations", "A complete introductory path"),
            card("technology", "Technology for AI", "Computing and network foundations"),
            card("psychology", "Human Intelligence", "Learning, memory, and decisions")
        ]),
        CourseShelf(title: "Science", items: [
            card("science", "Core Science", "Matter, energy, and life"),
            card("space", "Astronomy", "Stars, galaxies, and gravity"),
            card("psychology", "Behavioral Science", "How minds interpret the world")
        ]),
        CourseShelf(title: "History", items: [
            card("history", "World History", "Ancient worlds to modern conflict"),
            card("economics", "Economic History", "Trade, labor, and growth"),
            card("design", "History of Design", "Systems that shaped daily life")
        ]),
        CourseShelf(title: "Health", items: [
            card("psychology", "Mental Health Foundations", "Emotion, habits, and decisions"),
            card("sports", "Movement & Recovery", "Strength, endurance, and rest"),
            card("science", "Human Biology", "Life, energy, and evidence")
        ]),
        CourseShelf(title: "Politics", items: [
            card("history", "Political History", "Power, institutions, and conflict"),
            card("economics", "Political Economy", "Policy, incentives, and trade"),
            card("psychology", "Public Opinion", "Perception and decision making")
        ]),
        CourseShelf(title: "Cooking", items: [
            card("cooking", "Cooking Science", "Heat, texture, and timing"),
            card("science", "Food Chemistry", "Matter and energy in the kitchen"),
            card("business", "Food Business", "Customers and operations")
        ]),
        CourseShelf(title: "Sports", items: [
            card("sports", "Sports Science", "Movement through teamwork"),
            card("psychology", "Performance Psychology", "Learning, habits, and focus"),
            card("science", "Physics of Sport", "Energy, matter, and motion")
        ]),
        CourseShelf(title: "Economics", items: [
            card("economics", "Economics", "Scarcity through growth"),
            card("finance", "Markets & Investing", "Stocks, bonds, and valuation"),
            card("business", "Business Economics", "Models, strategy, and scale")
        ])
    ]

    static var bookSummaries: [CourseCard] {
        shelves.first { $0.title == "Book courses" }?.items ?? []
    }

    static var courseCards: [CourseCard] {
        var seen = Set<String>()
        var out: [CourseCard] = []
        for path in CourseStudio.generated {
            let card = CourseCard(pathID: path.id, title: path.title, subtitle: path.description, progress: LearningProgress.fraction(for: path))
            if seen.insert(path.id).inserted { out.append(card) }
        }
        for shelf in shelves where shelf.title != "Book courses" {
            for item in shelf.items where !item.pathID.hasPrefix("book-") {
                if seen.insert(item.pathID).inserted { out.append(item) }
            }
        }
        return out
    }

    private static func path(_ id: String, _ title: String, _ description: String, _ symbol: String, _ lessons: [LearningLesson]) -> LearningPath {
        LearningPath(id: id, title: title, description: description, symbol: symbol, lessons: lessons)
    }

    private static func lesson(_ title: String, _ core: String, _ mechanism: String, _ application: String) -> LearningLesson {
        LearningLesson(title: title, core: core, mechanism: mechanism, application: application)
    }

    private static func card(_ pathID: String, _ title: String, _ subtitle: String, _ progress: Double? = nil) -> CourseCard {
        CourseCard(pathID: pathID, title: title, subtitle: subtitle, progress: progress)
    }
}
