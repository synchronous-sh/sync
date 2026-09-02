import Foundation
import SwiftUI

struct LearningPath: Identifiable, Hashable {
    var id: String
    var title: String
    var description: String
    var symbol: String
    var lessons: [LearningLesson]
}

struct LearningLesson: Identifiable, Hashable {
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

    static func completed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isComplete(pathID: String, lesson: String) -> Bool {
        completed().contains("\(pathID):\(lesson)")
    }

    static func toggle(pathID: String, lesson: String) {
        var items = completed()
        let token = "\(pathID):\(lesson)"
        if items.contains(token) { items.remove(token) } else { items.insert(token) }
        UserDefaults.standard.set(Array(items), forKey: key)
    }

    static func fraction(for path: LearningPath) -> Double {
        guard !path.lessons.isEmpty else { return 0 }
        let done = path.lessons.filter { isComplete(pathID: path.id, lesson: $0.title) }.count
        return Double(done) / Double(path.lessons.count)
    }
}

enum LearningCatalog {
    static func path(id: String) -> LearningPath? {
        paths.first { $0.id == id }
    }

    static let paths: [LearningPath] = [
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
        ])
    ]

    static let shelves: [CourseShelf] = [
        CourseShelf(title: "Recents", items: [
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
