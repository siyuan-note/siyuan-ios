//
//  IAPManager.swift
//  siyuan-ios
//
//  Created by Vanessa on 2025/3/18.
//

import StoreKit
import Iosk
@available(iOS 15.0, *)
@MainActor
class IAPManager:ObservableObject {
    static let shared = IAPManager()
    private init() {}
    @Published var productID = ["china00", "china02", "00", "02"]  //  需要内购的产品ID数组
    @Published var products: [Product] = []    // 存储从 App Store 获取的内购商品信息
    // 视图自动加载loadProduct()方法
    func loadProduct() async {
        do {
            // 传入 productID 产品ID数组，调取Product.products接口从App Store返回产品信息
            // App Store会返回对应的产品信息，如果数组中个别产品ID有误，只会返回正确的产品ID的产品信息
            let fetchedProducts = try await Product.products(for: productID)
            if fetchedProducts.isEmpty {    // 判断返回的是否是否为空
                // 抛出内购信息为空的错误,可能是所有的产品ID都不存在，中断执行，不会return返回products产品信息
                throw StoreError.IAPInformationIsEmpty
            }
            
            self.products = fetchedProducts  // 将获取的内购商品保存到products变量
            print("成功加载产品: \(products)")    // 输出内购商品数组信息
        } catch {
            print("加载产品失败：\(error)")    // 输出报错
        }
    }
    // purchaseProduct：购买商品的方法，返回购买结果
    func purchaseProduct(_ product: Product, uuid:UUID) {
        // 在这里输出要购买的商品id
        print("Purchasing product: \(product.id)")
        Task {  @MainActor in
            do {
                let result = try await product.purchase(options: [.appAccountToken(uuid)])
                switch result {
                case .success(let verification):    // 购买成功的情况，返回verification包含交易的验证信息
                    let transaction = try checkVerified(verification)    // 验证交易
                    savePurchasedState(for: product.id)    // 更新UserDefaults中的购买状态
                    await transaction.finish()    // 告诉系统交易完成
                    let response = Iosk.MobileVerifyAppStoreTransaction(uuid.uuidString, String(transaction.id));
                    DispatchQueue.main.asyncAfter(deadline: .now()) {
                        ViewController.syWebView.evaluateJavaScript("processIOSPurchaseResponse(" + String(response) + ")")
                    }
                case .userCancelled:    // 用户取消交易
                    DispatchQueue.main.asyncAfter(deadline: .now()) {
                        ViewController.syWebView.evaluateJavaScript("processIOSPurchaseResponse(-10)")
                    }
                case .pending:    // 购买交易被挂起
                    DispatchQueue.main.asyncAfter(deadline: .now()) {
                        ViewController.syWebView.evaluateJavaScript("processIOSPurchaseResponse(-11)")
                    }
                default:    // 其他情况
                    DispatchQueue.main.asyncAfter(deadline: .now()) {
                        ViewController.syWebView.evaluateJavaScript("processIOSPurchaseResponse(-12)")
                    }
                    throw StoreError.failedVerification    // 购买失败
                }
            } catch {
                print("购买失败：\(error)")
                await resetProduct()    // 购买失败后重置 product 以便允许再次尝试购买
            }
        }
    }
    // 验证购买结果
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:    // unverified校验失败，StoreKit不能确定交易有效
            print("校验购买结果失败")
            throw StoreError.failedVerification
        case .verified(let signedType):    // verfied校验成功
            print("校验购买结果成功")
            return signedType    // StoreKit确认本笔交易信息由苹果服务器合法签署
        }
    }
    // handleTransactions处理所有的交易情况
    func handleTransactions() async {
        for await result in Transaction.updates {
            // 遍历当前所有已完成的交易
            do {
                let transaction = try checkVerified(result) // 验证交易
                // 处理交易，例如解锁内容
                savePurchasedState(for: transaction.productID)
                await transaction.finish()
            } catch {
                print("交易处理失败：\(error)")
            }
        }
    }
    // 当购买失败时，会尝试重新加载产品信息。
    func resetProduct() async {
        self.products = []
        await loadProduct()    // 调取loadProduct方法获取产品信息
    }
    // 保存购买状态到用户偏好设置或其他存储位置
    func savePurchasedState(for productID: String) {
        UserDefaults.standard.set(true, forKey: productID)
        print("Purchased state saved for product: \(productID)")
    }
    // 通过productID检查是否已完成购买
    func loadPurchasedState(for productID: String) -> Bool{
        let isPurchased = UserDefaults.standard.bool(forKey: productID)    // UserDefaults读取购买状态
        print("Purchased state loaded for product: \(productID) - \(isPurchased)")
        return isPurchased    // 返回购买状态
    }
}
// 定义 throws 报错
enum StoreError: Error {
    case IAPInformationIsEmpty
    case failedVerification
}
