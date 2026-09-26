import Foundation
import Testing
@testable import SiriCore

/// Date, orari e numeri nelle richieste in inglese: gli stessi conti dell'italiano, con parole e formati inglesi.
/// In italiano tutto resta come prima (lo controllano anche CalculationsTests e AppChangesTests).
@Suite struct EnglishDatesNumbersTests {
    /// Mercoledì 23 settembre 2026, ore 10.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10))!

    func day(_ day: Int, month: Int = 9, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func english(_ body: () throws -> Void) rethrows { try Language.$scoped.withValue(.en, operation: body) }
    func italian(_ body: () throws -> Void) rethrows { try Language.$scoped.withValue(.it, operation: body) }

    @Test func numbers() {
        english {
            #expect(Calculations.number("1,580") == 1580)
            #expect(Calculations.number("89.90") == 89.9)
            #expect(Calculations.number("2,450.50") == 2450.5)
            #expect(Calculations.number("12,500") == 12500)
            #expect(Calculations.number("3,5") == 3.5)
            #expect(Calculations.numbers(in: "It costs €89.90 with 22% VAT, 1,580 for 12,500 units, 3/8 of it") == [89.9, 22, 1580, 12500, 3, 8])
            #expect(Calculations.format(1580.5) == "1,580.5")
            #expect(Calculations.format(69104) == "69,104")
            #expect(Calculations.canonicalNumbers("split 2,450.50 euros among 7, then 89.90 and 12,500") == "split 2450.5 euros among 7, then 89.90 and 12500")
            #expect(Calculations.evaluate("1,580 * 22 / 100") == 347.6)
            #expect(Calculations.evaluate("min(3,7,5)") == 3)
            #expect(Calculations.evaluate("1,234,567 + 1") == 1_234_568)
        }
        italian {
            #expect(Calculations.number("1.580") == 1580)
            #expect(Calculations.number("89,90") == 89.9)
            #expect(Calculations.format(347.6) == "347,6")
            #expect(Calculations.canonicalNumbers("89,90 e 2.450") == "89.9 e 2450")
        }
    }

    @Test func directFacts() {
        english {
            #expect(Calculations.directFacts(in: "What's 22% of 1,580 euros?") == ["22% of 1,580 = 347.6"])
            #expect(Calculations.directFacts(in: "What's 1,234 times 56?") == ["1,234 × 56 = 69,104"])
            #expect(Calculations.directFacts(in: "What's the square root of 1,764?") == ["square root of 1,764 = 42"])
            #expect(Calculations.directFacts(in: "What is 3/8 of 2,000?") == ["3/8 of 2,000 = 750"])
            #expect(Calculations.directFacts(in: "calculate 100 divided by 8") == ["100 ÷ 8 = 12.5"])
            #expect(Calculations.directFacts(in: "What's the capital of France?").isEmpty)
            #expect(Calculations.looksArithmetic("A product costs €89.90 including 22% VAT. How much is it without VAT?"))
            #expect(Calculations.looksArithmetic("I need to split 2,450 euros equally among 7 people: how much does each person get?"))
            #expect(!Calculations.looksArithmetic("Summarize the private notes from 2025"))
            #expect(Calculations.plausible("2450 / 7", prompt: Calculations.canonicalNumbers("split 2,450 euros among 7 people")))
        }
    }

    @Test func dateFacts() {
        english {
            let weekday = Calculations.dateFacts(in: "What day of the week will December 25, 2026 be?", now: now)
            #expect(weekday.first == "Today is Wednesday, September 23, 2026.")
            #expect(weekday.contains("December 25, 2026 will be a Friday."))
            let christmas = Calculations.dateFacts(in: "How many days until Christmas?", now: now)
            #expect(christmas.contains("There are 93 days until Christmas (Friday, December 25, 2026), that is 13 weeks and 2 days."))
            #expect(Calculations.dateFacts(in: "What date will it be in 45 days?", now: now).contains("In 45 days it will be Saturday, November 7, 2026."))
            let span = Calculations.dateFacts(in: "How many days are there between March 3, 2026 and April 15, 2026?", now: now)
            #expect(span.contains { $0.hasPrefix("From March 3, 2026 to April 15, 2026 the difference is 43 days") })
            #expect(Calculations.dateFacts(in: "What day of the week was July 4, 1976?", now: now).contains("July 4, 1976 was a Sunday."))
            #expect(Calculations.dateFacts(in: "What day of the week was the 4th of July 1976?", now: now).contains("July 4, 1976 was a Sunday."))
            #expect(Calculations.dateFacts(in: "How many days since Christmas Eve?", now: now)
                .contains("273 days have passed since Christmas Eve (Wednesday, December 24, 2025)."))
            #expect(Calculations.dateFacts(in: "What was the date 3 weeks ago?", now: now).contains("3 weeks ago it was Wednesday, September 2, 2026."))
            #expect(Calculations.dateFacts(in: "How many days until Easter?", now: now).contains { $0.contains("Easter (Sunday, March 28, 2027)") })
            #expect(Calculations.dateFacts(in: "How many days are left until Thanksgiving?", now: now)
                .contains { $0.contains("Thanksgiving (Thursday, November 26, 2026)") })
            #expect(Calculations.dateFacts(in: "What day of the week is the 4th of July this year?", now: now).contains("July 4, 2026 was a Saturday."))
            #expect(Calculations.dateFacts(in: "When is Christmas?", now: now).contains { $0.contains("Christmas (Friday, December 25, 2026)") })
            #expect(Calculations.dateFacts(in: "What do I have tomorrow?", now: now).isEmpty)
        }
    }

    @Test func weekdayFacts() {
        english {
            #expect(Calculations.weekdayFacts(in: "If today were Wednesday, what day is in 3 days?")
                == ["Counting from today (Wednesday), in 3 days it is Saturday (3 days later)."])
            #expect(Calculations.weekdayFacts(in: "If today is Friday, what day was it 3 days ago?") == ["Counting from today (Friday), 3 days ago it was Tuesday."])
            #expect(Calculations.weekdayFacts(in: "If the 5th is a Monday, what day is 3 working days before?")
                == ["3 working days before the 5th (Monday): Wednesday (Saturday and Sunday don't count)."])
            #expect(Calculations.weekdayFacts(in: "What day of the week will December 25, 2026 be?").isEmpty)
        }
    }

    @Test func timeFacts() {
        english {
            #expect(Calculations.timeFacts(in: "How much time passes between 9:40 and 17:15?") == ["From 9:40 to 17:15 there are 7 hours and 35 minutes."])
            let meetings = Calculations.timeFacts(in: "I have three meetings tomorrow: 9:00-10:30, 10:00-11:00 and 14:00-15:00. Which ones overlap, and how many free hours do I have in total between 9 and 17?")
            #expect(meetings.contains("9:00–10:30 and 10:00–11:00 overlap from 10:00 to 10:30 (30 minutes)."))
            #expect(meetings.contains("Free time between 9:00 and 17:00: 5 hours in total (11:00–14:00, 3 hours; 15:00–17:00, 2 hours)."))
            let pause = Calculations.timeFacts(in: "Tomorrow I'm busy from 8:30 to 12:00 and from 13:15 to 18:00. How long is the break in between?")
            #expect(pause.contains("Breaks between the time slots: 12:00–13:15 (1 hour and 15 minutes)."))
            let sum = Calculations.timeFacts(in: "I worked 7 hours 45 minutes on Monday, 8 hours 20 on Tuesday and 6 hours 50 on Wednesday. How many hours in total?")
            #expect(sum.last == "Sum: 7 hours and 45 minutes + 8 hours and 20 minutes + 6 hours and 50 minutes = 22 hours and 55 minutes.")
            #expect(Calculations.timeFacts(in: "From 9 am to 5:30 pm, how long is that?") == ["From 9:00 to 17:30 there are 8 hours and 30 minutes."])
            #expect(Calculations.timeFacts(in: "How much time is there between noon and 2 pm?") == ["From 12:00 to 14:00 there are 2 hours."])
            #expect(Calculations.hasExplicitSchedule("Meetings 9am-10:30am and 10-11:30 am: do they overlap?"))
            #expect(Calculations.window(in: "what do i have between 9 and 5?") == Calculations.Span(start: 9 * 60, end: 17 * 60))
            #expect(Calculations.timeFacts(in: "Schedule a meeting tomorrow at 3 pm").isEmpty)
            #expect(Calculations.duration(61) == "1 hour and 1 minute")
        }
    }

    @Test func days() {
        english {
            func first(_ text: String) -> Date? { DateExpressions.days(in: text, now: now).first?.date }
            #expect(first("tomorrow") == day(24))
            #expect(first("the day after tomorrow") == day(25))
            #expect(first("yesterday") == day(22))
            #expect(first("tonight") == day(23))
            #expect(first("on Friday") == day(25))
            #expect(first("this Friday") == day(25))
            #expect(first("next Friday") == day(25))
            #expect(first("Wednesday") == day(23))
            #expect(first("next Wednesday") == day(30))
            #expect(first("next Monday morning") == day(28))
            #expect(first("last Friday") == day(18))
            #expect(first("Friday next week") == day(2, month: 10))
            #expect(first("Friday after next") == day(2, month: 10))
            #expect(first("Wednesday after next") == day(7, month: 10))
            #expect(first("in 3 days") == day(26))
            #expect(first("in two weeks") == day(7, month: 10))
            #expect(first("a week from today") == day(30))
            #expect(first("this weekend") == day(26))
            #expect(first("October 15 at 9:30") == day(15, month: 10))
            #expect(first("15 October") == day(15, month: 10))
            #expect(first("Oct. 15th") == day(15, month: 10))
            #expect(first("the 1st of November 2027") == day(1, month: 11, year: 2027))
            #expect(first("January 10") == day(10, month: 1, year: 2027))
            #expect(first("Friday, October 2") == day(2, month: 10))
            #expect(first("12/25") == day(25, month: 12))
            #expect(first("2026-10-15") == day(15, month: 10))
            #expect(first("what is 3 plus 4") == nil)
            let move = DateExpressions.days(in: "move tomorrow's meeting to Friday", now: now)
            #expect(move.map(\.role) == [.target, .destination] && move.map(\.date) == [day(24), day(25)])
            #expect(DateExpressions.days(in: "move the call from Thursday to Friday", now: now).map(\.role) == [.target, .destination])
            #expect(DateExpressions.days(in: "cancel the meeting on Friday", now: now).first?.role == .bare)
        }
    }

    @Test func times() {
        english {
            func first(_ text: String) -> Int? { DateExpressions.times(in: text).first?.minutes }
            #expect(first("tomorrow at 3 pm") == 15 * 60)
            #expect(first("at 3pm") == 15 * 60)
            #expect(first("at 5:30 p.m.") == 17 * 60 + 30)
            #expect(first("at 10 am") == 10 * 60)
            #expect(first("at 12 am") == 0)
            #expect(first("at 15:00") == 15 * 60)
            #expect(first("on Friday at 10") == 10 * 60)
            #expect(first("at 3") == 15 * 60)
            #expect(first("tomorrow morning at 7") == 7 * 60)
            #expect(first("dinner at 8") == 20 * 60)
            #expect(first("at 8 in the evening") == 20 * 60)
            #expect(first("at noon") == 12 * 60)
            #expect(first("at midnight") == 0)
            #expect(first("at half past 9") == 9 * 60 + 30)
            #expect(first("at a quarter to 4") == 15 * 60 + 45)
            #expect(first("at seven in the evening") == 19 * 60)
            #expect(first("at 9.30") == 9 * 60 + 30)
            #expect(first("October 15 at 9:30") == 9 * 60 + 30)
            #expect(first("delete slide 3") == nil)
            #expect(first("book a table for 3 people") == nil)
            #expect(first("postpone it by 2 hours") == nil)
            #expect(first("move slide 3 to 5") == nil)
            #expect(first("it costs 9.30") == nil)
            #expect(DateExpressions.times(in: "move it to tomorrow from 3 to 5 pm").map(\.minutes) == [15 * 60, 17 * 60])
            #expect(DateExpressions.times(in: "move the 10am to 11").map(\.minutes) == [10 * 60, 11 * 60])
            #expect(first("move the call to 3 this afternoon") == 15 * 60)
            #expect(first("call Marco at 9 tonight") == 21 * 60)
            #expect(DateExpressions.times(in: "the meeting from 10").first?.role == .target)
            #expect(DateExpressions.times(in: "move it to 4 pm").first?.role == .destination)
            #expect(DateExpressions.times(in: "move the 3pm meeting").first?.role == .bare)
        }
    }

    @Test func shifts() {
        english {
            let earlier = DateExpressions.shifts(in: "half an hour earlier").first
            #expect(earlier?.seconds == 1800 && earlier?.direction == -1)
            let later = DateExpressions.shifts(in: "one hour later").first
            #expect(later?.seconds == 3600 && later?.direction == 1)
            let by = DateExpressions.shifts(in: "postpone it by one hour").first
            #expect(by?.seconds == 3600 && by?.direction == 0)
            #expect(DateExpressions.shifts(in: "push it back by one hour").first?.direction == 1)
            #expect(DateExpressions.shifts(in: "postpone by 30 minutes").first?.seconds == 1800)
            let back = DateExpressions.shifts(in: "push it back two days").first
            #expect(back?.days == 2 && back?.direction == 1)
            let forward = DateExpressions.shifts(in: "bring the meeting forward by an hour").first
            #expect(forward?.seconds == 3600 && forward?.direction == -1)
            #expect(DateExpressions.shifts(in: "move it a day later").first?.days == 1)
            #expect(DateExpressions.shifts(in: "move it to next week").first?.days == 7)
            #expect(DateExpressions.shifts(in: "the day after").first?.days == 1)
            #expect(DateExpressions.shifts(in: "for two hours").isEmpty)
            #expect(DateExpressions.shifts(in: "Friday next week").isEmpty)
            #expect(DateExpressions.shifts(in: "the day after tomorrow").isEmpty)
        }
    }

    @Test func keywords() {
        english {
            #expect(Keywords.words("Could you move the dentist appointment to 4 pm please") == ["dentist", "appointment"])
            #expect(Keywords.specific(Keywords.words("reschedule my call with Luca")) == ["luca"])
            #expect(Keywords.specific(Keywords.words("move the appointment with the dentist")) == ["dentist"])
            #expect(Keywords.stem("meetings") == Keywords.stem("meeting"))
            #expect(Keywords.stem("parties") == Keywords.stem("party"))
            #expect(Keywords.stem("invoices") == Keywords.stem("invoice"))
            #expect(Keywords.stem("bollette") == "bollett")
            #expect(Keywords.score("Pay the bills", against: ["bill"]) == 3)
        }
        italian {
            #expect(Keywords.stem("bollette") == "bollett")
            #expect(Keywords.words("sposta la riunione con Marco") == ["riunione", "marco"])
        }
    }

    @Test func friendlyDates() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: .now)!)!
        english {
            #expect(Dates.friendly(tomorrow).hasPrefix("tomorrow at 3:00"))
            #expect(Dates.friendly(tomorrow, time: false) == "tomorrow")
            #expect(Dates.upcomingDays(2).hasSuffix("(tomorrow)"))
            #expect(Dates.upcomingDays(2).contains("(today)"))
            #expect(Dates.upcomingDays(7).contains("Monday"))
        }
        italian {
            #expect(Dates.friendly(tomorrow) == "domani alle 15:00")
            #expect(Dates.upcomingDays(2).hasSuffix("(domani)"))
        }
    }

    @Test @MainActor func evaluationChecks() throws {
        let data = Data(#"""
        [{"id": "d", "domanda": "What date will it be in 45 days?", "deve": ["{{data:+45:d MMMM}}"]},
         {"id": "c", "domanda": "How many days until Christmas?", "deve": ["\\b{{giorni:12-25}}\\b"]}]
        """#.utf8)
        let cases = try JSONDecoder().decode([EvalCase].self, from: data)
        #expect(Evaluation.check("It will be Saturday, November 7.", test: cases[0], outcome: "risposta", usedWeb: false, now: now).isEmpty)
        #expect(Evaluation.check("It will be 7 November.", test: cases[0], outcome: "risposta", usedWeb: false, now: now).isEmpty)
        #expect(!Evaluation.check("Sarà il 7 novembre.", test: cases[0], outcome: "risposta", usedWeb: false, now: now).isEmpty)
        #expect(Evaluation.check("There are **93** days left.", test: cases[1], outcome: "risposta", usedWeb: false, now: now).isEmpty)
        #expect(Language.$scoped.withValue(.en) { Evaluation.expand("{{data:+2:EEEE}}", now: now) } == "Friday")
    }
}
