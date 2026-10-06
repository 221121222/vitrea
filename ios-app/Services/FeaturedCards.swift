//
//  FeaturedCards.swift
//  Vitrea
//
//  精选卡面清单：站点链接中标注为精选的卡面，按 ID 内置在这里。
//  需要增删时直接改下面的 seeds 即可（id = cardart.cc 卡面 ID，version = 图片版本号）。
//

import Foundation

struct FeaturedCardSeed {
    let id: String
    let version: String
    let title: String
    let author: String?
}

enum FeaturedCards {

    static let seeds: [FeaturedCardSeed] = [
        FeaturedCardSeed(id: "1G5SCCRKr7", version: "v1", title: "麦当劳招商银行银联借记卡", author: "li_khixang"),
        FeaturedCardSeed(id: "1Imon7tEsp", version: "v1", title: "HSBC Credit  (Cat Edition)", author: "mg2wkp6dvv"),
        FeaturedCardSeed(id: "1S50bNV7r3", version: "v1", title: "上海银行", author: "xiuchao"),
        FeaturedCardSeed(id: "49MBawnHCW", version: "v1", title: "Dollar SP", author: "5knhh8th24"),
        FeaturedCardSeed(id: "C95AjCePHO", version: "v1", title: "GOLD SPARKASSE MASTERCARD", author: "userusersky6"),
        FeaturedCardSeed(id: "IihojBrxpA", version: "v2", title: "Ichimatsu Noir", author: nil),
        FeaturedCardSeed(id: "Io0S49NWqv", version: "v1", title: "御坂 Tmoney", author: "moraxyc"),
        FeaturedCardSeed(id: "JzPsUWjvCZ", version: "v1", title: "American Depress", author: "5knhh8th24"),
        FeaturedCardSeed(id: "M5GeFeuiTf", version: "v1", title: "肯德基招商银行银联信用卡", author: "li_khixang"),
        FeaturedCardSeed(id: "NOjFZ159ZY", version: "v1", title: "交通一卡通·昆明智慧通", author: "kfc"),
        FeaturedCardSeed(id: "OKULBTgm9w", version: "v1", title: "HSBC Debit  (Cat Edition)", author: "mg2wkp6dvv"),
        FeaturedCardSeed(id: "R0Dbr1GjHA", version: "v1", title: "交通一卡通 (全球通)", author: "kfc"),
        FeaturedCardSeed(id: "VD7aMFEoRQ", version: "v1", title: "上海银行", author: "xiuchao"),
        FeaturedCardSeed(id: "VmdtFd5ur1", version: "v1", title: "Cat", author: "aguselgueta01"),
        FeaturedCardSeed(id: "XN0YNuK0Mw", version: "v1", title: "Revolut Ultra", author: "trazbozkurt"),
        FeaturedCardSeed(id: "XmrPDMhRmy", version: "v1", title: "交通一卡通 (全球通) V2", author: "kfc"),
        FeaturedCardSeed(id: "aivSz9EErS", version: "v2", title: "Tsukimi Susuki", author: nil),
        FeaturedCardSeed(id: "c86fbmbxEv", version: "v1", title: "Galicia Eminent VISA Signature", author: "123ca"),
        FeaturedCardSeed(id: "eG16v9TNaV", version: "v1", title: "ZA miku", author: "moraxyc"),
        FeaturedCardSeed(id: "frAKuvSy64", version: "v1", title: "Apple cash liquid glass 0.1", author: "5knhh8th24"),
        FeaturedCardSeed(id: "hio59CqdI9", version: "v1", title: "哆啦A梦招商银行VISA信用卡", author: "li_khixang"),
        FeaturedCardSeed(id: "j0HZfeMlRq", version: "v1", title: "上海银行", author: "xiuchao"),
        FeaturedCardSeed(id: "pAgSVGjwsN", version: "v1", title: "Nightmare", author: "cardsleeves"),
        FeaturedCardSeed(id: "porgEy21yC", version: "v4", title: "Asanoha Kiriko", author: nil),
        FeaturedCardSeed(id: "q8onS48XSQ", version: "v1", title: "远坂凛", author: "2wf6tgdcsn"),
        FeaturedCardSeed(id: "tGi573XXYY", version: "v1", title: "HSBC Credit (Cat Edition)", author: "mg2wkp6dvv"),
        FeaturedCardSeed(id: "xCoM1Jtkct", version: "v1", title: "初音未来小柠檬", author: "moraxyc"),
    ]

    /// 把精选清单解析成可直接展示的卡面（图片地址按 ID + 版本号拼出）
    static func makeCards() -> [GalleryCard] {
        seeds.map { seed in
            let base = "/img/cards/\(seed.id)/\(seed.version)"
            return GalleryCard(
                id: seed.id,
                title: seed.title,
                titleEn: nil,
                dominantColor: nil,
                images: GalleryImages(
                    png: "\(base)/card.png",
                    w1536: "\(base)/w1536.webp",
                    w1024: "\(base)/w1024.webp",
                    w640: "\(base)/w640.webp",
                    w480: "\(base)/w480.webp"
                ),
                author: GalleryAuthor(
                    id: seed.author ?? seed.id,
                    name: seed.author ?? "未知作者",
                    handle: seed.author,
                    image: nil
                ),
                likeCount: nil,
                downloadCount: nil
            )
        }
    }
}
