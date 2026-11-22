import Foundation

/// Sık oynanan bir oyunun hazır ayarı: çeviride olduğu gibi kalması gereken karakter ve yer adları.
/// Kullanıcı oyununu listeden seçince bu adlar "çevrilmeyecek adlar" listesine hazır gelir.
public struct GamePack: Equatable, Sendable, Identifiable {
    public let name: String
    public let terms: [String]
    public var id: String { name }
    /// Paketteki adlardan kadın karakter olanlar (dublajda ses seçimi için). Paketteki öteki kişi adları erkektir.
    public var women: [String] { GamePacks.women[name] ?? [] }
}

public enum GamePacks {
    /// Oyunun adına göre paket (büyük-küçük harf ayırmadan).
    public static func find(_ name: String) -> GamePack? {
        all.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    /// Kadın karakterler (dublajda kadın sesiyle okunur). Cinsiyeti oyuncunun seçimine bağlı ya da belirsiz
    /// olanlar ("Eivor", "Weasley") bilerek yoktur.
    static let women: [String: [String]] = [
        "Alan Wake 2": ["Saga", "Alice"],
        "Assassin's Creed": ["Naoe", "Randvi", "Layla", "Roshan"],
        "Baldur's Gate 3": ["Shadowheart", "Lae'zel", "Karlach", "Minthara", "Jaheira", "Orin", "Shar", "Selûne"],
        "Call of Duty: Black Ops 6": ["Harrow", "Sev", "Park"],
        "Call of Duty: Modern Warfare": ["Farah", "Laswell", "Valeria"],
        "Cyberpunk 2077": ["Judy", "Panam", "Evelyn", "Rogue", "Misty", "Songbird"],
        "Death Stranding": ["Fragile", "Mama", "Amelie", "Lockne"],
        "Detroit: Become Human": ["Kara", "Alice", "North"],
        "Elden Ring": ["Melina", "Ranni", "Rennala", "Malenia", "Marika", "Fia"],
        "Final Fantasy VII": ["Tifa", "Aerith", "Yuffie", "Jenova"],
        "Ghost of Tsushima": ["Yuna", "Masako", "Tomoe"],
        "God of War": ["Freya", "Angrboda", "Faye"],
        "Grand Theft Auto V": ["Amanda", "Tracey"],
        "Hogwarts Legacy": ["Natsai", "Poppy"],
        "Horizon": ["Aloy", "Zo", "Beta", "Tilda", "Regalla", "GAIA"],
        "Marvel's Spider-Man": ["MJ", "Rio", "Yuri", "Hailey", "Aunt May"],
        "Red Dead Redemption 2": ["Abigail", "Sadie", "Molly", "Susan", "Tilly", "Karen", "Mary-Beth"],
        "Resident Evil 4": ["Ashley", "Ada", "Hunnigan"],
        "Star Wars Jedi": ["Cere", "Merrin"],
        "The Last of Us": ["Ellie", "Tess", "Marlene", "Riley", "Abby", "Dina", "Yara", "Mel"],
        "The Witcher 3": ["Ciri", "Yennefer", "Triss", "Keira"],
        "Uncharted 4": ["Elena", "Nadine"],
    ]

    /// Adlar oyunda yazıldığı gibidir. Tek harfli ya da cümle başında sıradan kelime olan adlar
    /// ("V", "May") bilerek yoktur: korunursa sıradan cümleleri bozar.
    public static let all: [GamePack] = [
        GamePack(name: "Alan Wake 2", terms: [
            "Alan", "Saga", "Casey", "Alice", "Scratch", "Bright Falls", "Cauldron Lake", "Watery", "Anderson", "Zane"]),
        GamePack(name: "Assassin's Creed", terms: [
            "Eivor", "Sigurd", "Basim", "Naoe", "Yasuke", "Randvi", "Layla", "Ravensthorpe", "Roshan", "Animus", "Abstergo"]),
        GamePack(name: "Baldur's Gate 3", terms: [
            "Astarion", "Shadowheart", "Gale", "Lae'zel", "Karlach", "Wyll", "Halsin", "Minthara", "Jaheira", "Minsc",
            "Withers", "Raphael", "Ketheric", "Gortash", "Orin", "Baldur's Gate", "Faerûn", "Moonrise", "Shar", "Selûne"]),
        GamePack(name: "Call of Duty: Black Ops 6", terms: [
            "Woods", "Adler", "Marshall", "Harrow", "Sev", "Felix", "Case", "Livingstone", "Park", "Pantheon", "Avalon", "Rook"]),
        GamePack(name: "Call of Duty: Modern Warfare", terms: [
            "Price", "Soap", "Ghost", "Gaz", "Farah", "Alex", "Laswell", "Shepherd", "Graves", "Makarov", "Nikolai", "Roach",
            "König", "Alejandro", "Rodolfo", "Valeria", "Hassan", "Zakhaev", "Barkov", "Hadir", "Shadow Company",
            "Task Force 141", "Urzikstan", "Verdansk", "Al Mazrah", "Las Almas", "Kastovia"]),
        GamePack(name: "Cyberpunk 2077", terms: [
            "Jackie", "Judy", "Panam", "Johnny", "Silverhand", "Takemura", "Dexter", "Evelyn", "Rogue", "Kerry", "Misty",
            "Viktor", "Arasaka", "Militech", "Night City", "Afterlife", "Songbird", "Reed", "Dogtown"]),
        GamePack(name: "Death Stranding", terms: [
            "Sam", "Fragile", "Deadman", "Heartman", "Mama", "Die-Hardman", "Higgs", "Amelie", "Cliff", "Bridges", "Lockne"]),
        GamePack(name: "Detroit: Become Human", terms: [
            "Connor", "Kara", "Markus", "Hank", "Alice", "North", "Simon", "Josh", "Luther", "Kamski", "CyberLife", "Jericho"]),
        GamePack(name: "Elden Ring", terms: [
            "Melina", "Ranni", "Radahn", "Godrick", "Rennala", "Malenia", "Morgott", "Godfrey", "Radagon", "Marika",
            "Blaidd", "Fia", "Gideon", "Limgrave", "Caelid", "Liurnia", "Leyndell", "Torrent", "Miquella"]),
        GamePack(name: "Final Fantasy VII", terms: [
            "Cloud", "Tifa", "Aerith", "Barret", "Sephiroth", "Zack", "Yuffie", "Shinra", "Midgar", "Avalanche", "Jenova"]),
        GamePack(name: "Ghost of Tsushima", terms: [
            "Jin", "Shimura", "Khotun", "Yuna", "Taka", "Ishikawa", "Masako", "Norio", "Kenji", "Tomoe", "Ryuzo",
            "Tsushima", "Sakai", "Yarikawa", "Komoda"]),
        GamePack(name: "God of War", terms: [
            "Kratos", "Atreus", "Mimir", "Freya", "Brok", "Sindri", "Baldur", "Thor", "Odin", "Tyr", "Angrboda", "Heimdall",
            "Freyr", "Faye", "Loki", "Midgard", "Asgard", "Alfheim", "Helheim", "Vanaheim", "Svartalfheim", "Jötunheim",
            "Leviathan", "Ragnarök"]),
        GamePack(name: "Grand Theft Auto V", terms: [
            "Michael", "Franklin", "Trevor", "Lamar", "Lester", "Amanda", "Tracey", "Jimmy", "Dave", "Devin", "Chop",
            "Simeon", "Wade", "Ron", "Los Santos", "Blaine County", "Sandy Shores", "Vinewood", "Merryweather"]),
        GamePack(name: "Hogwarts Legacy", terms: [
            "Hogwarts", "Hogsmeade", "Fig", "Sebastian", "Ominis", "Natsai", "Poppy", "Ranrok", "Rookwood", "Weasley",
            "Gryffindor", "Slytherin", "Ravenclaw", "Hufflepuff"]),
        GamePack(name: "Horizon", terms: [
            "Aloy", "Rost", "Sylens", "Varl", "Erend", "Kotallo", "Zo", "Beta", "Tilda", "Regalla", "Hekarro", "GAIA",
            "HADES", "HEPHAESTUS", "Nora", "Carja", "Oseram", "Tenakth", "Utaru", "Meridian"]),
        GamePack(name: "Marvel's Spider-Man", terms: [
            "Peter", "Miles", "MJ", "Harry", "Norman", "Kraven", "Venom", "Ganke", "Rio", "Otto", "Yuri", "Martin Li",
            "Hailey", "Oscorp", "Aunt May"]),
        GamePack(name: "Red Dead Redemption 2", terms: [
            "Arthur", "Dutch", "Micah", "John", "Abigail", "Jack", "Hosea", "Sadie", "Charles", "Javier", "Bill", "Lenny",
            "Sean", "Uncle", "Pearson", "Strauss", "Molly", "Susan", "Tilly", "Karen", "Mary-Beth", "Trelawny", "Swanson",
            "Milton", "Cornwall", "Colm", "Bronte", "Blackwater", "Valentine", "Saint Denis", "Rhodes", "Strawberry",
            "Annesburg", "Pinkertons", "O'Driscolls"]),
        GamePack(name: "Resident Evil 4", terms: [
            "Leon", "Ashley", "Ada", "Luis", "Krauser", "Saddler", "Salazar", "Hunnigan", "Mendez", "Umbrella", "Los Illuminados"]),
        GamePack(name: "Star Wars Jedi", terms: [
            "Cal", "Cere", "Greez", "Merrin", "Bode", "BD-1", "Kestis", "Koboh", "Jedha", "Dagan", "Mantis"]),
        GamePack(name: "The Last of Us", terms: [
            "Joel", "Ellie", "Tess", "Tommy", "Marlene", "Bill", "Henry", "Sam", "David", "Riley", "Abby", "Dina", "Jesse",
            "Lev", "Yara", "Owen", "Mel", "Isaac", "Fireflies", "Seraphites", "Jackson"]),
        GamePack(name: "The Witcher 3", terms: [
            "Geralt", "Ciri", "Yennefer", "Triss", "Dandelion", "Zoltan", "Vesemir", "Eredin", "Emhyr", "Roche", "Keira",
            "Lambert", "Eskel", "Novigrad", "Velen", "Skellige", "Kaer Morhen", "Nilfgaard", "Redania", "Roach"]),
        GamePack(name: "Uncharted 4", terms: [
            "Nathan", "Nate", "Sam", "Sully", "Elena", "Rafe", "Nadine", "Avery", "Libertalia", "Drake"]),
    ]
}
