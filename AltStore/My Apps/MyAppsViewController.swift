//
//  MyAppsViewController.swift
//  AltStore
//
//  Created by Riley Testut on 7/16/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import MobileCoreServices
import Intents
import Combine

import AltStoreCore
import AltSign
import Roxas

import Nuke

private let maximumCollapsedUpdatesCount = 2

extension MyAppsViewController
{
    private enum Section: Int, CaseIterable
    {
        case noUpdates
        case updates
        case activeApps
        case inactiveApps
    }
}

class MyAppsViewController: UICollectionViewController
{
    private let coordinator = NSFileCoordinator()
    private let operationQueue = OperationQueue()
    
    private lazy var dataSource = self.makeDataSource()
    private lazy var noUpdatesDataSource = self.makeNoUpdatesDataSource()
    private lazy var updatesDataSource = self.makeUpdatesDataSource()
    private lazy var activeAppsDataSource = self.makeActiveAppsDataSource()
    private lazy var inactiveAppsDataSource = self.makeInactiveAppsDataSource()
    private lazy var hiddenUpdatesFetchedResultsController = self.makeHiddenUpdatesFetchedResultsController()
    
    private var prototypeUpdateCell: UpdateCollectionViewCell!
    private var sideloadingProgressView: UIProgressView!
    
    // State
    private var isUpdateSectionCollapsed = true
    private var expandedAppUpdates = Set<String>()
    private var isRefreshingAllApps = false
    private var refreshGroup: RefreshGroup?
    private var sideloadingProgress: Progress?
    private var dropDestinationIndexPath: IndexPath?
    private var isCheckingForUpdates = false
    
    private var _imagePickerInstalledApp: InstalledApp?
    
    // Cache
    private var cachedUpdateSizes = [String: CGSize]()
    
    private lazy var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter
    }()
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        NotificationCenter.default.addObserver(self, selector: #selector(MyAppsViewController.didFetchSource(_:)), name: AppManager.didFetchSourceNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(MyAppsViewController.importApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        // Allows us to intercept delegate callbacks.
        self.updatesDataSource.fetchedResultsController.delegate = self
        self.hiddenUpdatesFetchedResultsController.delegate = self
        
        self.collectionView.dataSource = self.dataSource
        self.collectionView.prefetchDataSource = self.dataSource
        self.collectionView.dragDelegate = self
        self.collectionView.dropDelegate = self
        self.collectionView.dragInteractionEnabled = true
                
        self.prototypeUpdateCell = UpdateCollectionViewCell.instantiate(with: UpdateCollectionViewCell.nib!)
        self.prototypeUpdateCell.contentView.translatesAutoresizingMaskIntoConstraints = false
        
        self.collectionView.register(UpdateCollectionViewCell.nib, forCellWithReuseIdentifier: "UpdateCell")
        self.collectionView.register(UpdatesCollectionHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "UpdatesHeader")
        self.collectionView.register(InstalledAppsCollectionHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "ActiveAppsHeader")
        self.collectionView.register(InstalledAppsCollectionHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "InactiveAppsHeader")
        
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(MyAppsViewController.checkForUpdates(_:)), for: .primaryActionTriggered)
        self.collectionView.refreshControl = refreshControl
        
        self.sideloadingProgressView = UIProgressView(progressViewStyle: .bar)
        self.sideloadingProgressView.translatesAutoresizingMaskIntoConstraints = false
        self.sideloadingProgressView.progressTintColor = .altPrimary
        self.sideloadingProgressView.progress = 0
        
        if let navigationBar = self.navigationController?.navigationBar
        {
            navigationBar.addSubview(self.sideloadingProgressView)
            NSLayoutConstraint.activate([self.sideloadingProgressView.leadingAnchor.constraint(equalTo: navigationBar.leadingAnchor),
                                         self.sideloadingProgressView.trailingAnchor.constraint(equalTo: navigationBar.trailingAnchor),
                                         self.sideloadingProgressView.bottomAnchor.constraint(equalTo: navigationBar.bottomAnchor)])
        }
        
        if #available(iOS 13, *) {}
        else
        {
            self.registerForPreviewing(with: self, sourceView: self.collectionView)
        }
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
        
        self.updateDataSource()
        
        self.fetchAppIDs()
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        guard let identifier = segue.identifier else { return }
        
        switch identifier
        {
        case "showApp", "showUpdate":
            guard let cell = sender as? UICollectionViewCell, let indexPath = self.collectionView.indexPath(for: cell) else { return }
            
            let installedApp = self.dataSource.item(at: indexPath)
            
            let appViewController = segue.destination as! AppViewController
            appViewController.app = installedApp.storeApp
            
        default: break
        }
    }
    
    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool
    {
        guard identifier == "showApp" else { return true }
        
        guard let cell = sender as? UICollectionViewCell, let indexPath = self.collectionView.indexPath(for: cell) else { return true }
        
        let installedApp = self.dataSource.item(at: indexPath)
        return !installedApp.isSideloaded
    }
    
    @IBAction func unwindToMyAppsViewController(_ segue: UIStoryboardSegue)
    {
    }
}

private extension MyAppsViewController
{
    func makeDataSource() -> RSTCompositeCollectionViewPrefetchingDataSource<InstalledApp, UIImage>
    {
        let dataSource = RSTCompositeCollectionViewPrefetchingDataSource<InstalledApp, UIImage>(dataSources: [self.noUpdatesDataSource, self.updatesDataSource, self.activeAppsDataSource, self.inactiveAppsDataSource])
        dataSource.proxy = self
        return dataSource
    }
    
    func makeNoUpdatesDataSource() -> RSTDynamicCollectionViewPrefetchingDataSource<InstalledApp, UIImage>
    {
        let dynamicDataSource = RSTDynamicCollectionViewPrefetchingDataSource<InstalledApp, UIImage>()
        dynamicDataSource.numberOfSectionsHandler = { 1 }
        dynamicDataSource.numberOfItemsHandler = { _ in self.updatesDataSource.itemCount == 0 ? 1 : 0 }
        dynamicDataSource.cellIdentifierHandler = { _ in "NoUpdatesCell" }
        dynamicDataSource.cellConfigurationHandler = { (cell, _, indexPath) in
            let cell = cell as! NoUpdatesCollectionViewCell
            cell.layoutMargins.left = self.view.layoutMargins.left
            cell.layoutMargins.right = self.view.layoutMargins.right
            
            cell.blurView.layer.cornerRadius = 20
            cell.blurView.layer.masksToBounds = true
            cell.blurView.backgroundColor = .altPrimary
            
            cell.button.addTarget(self, action: #selector(MyAppsViewController.showHiddenUpdatesAlert(_:)), for: .primaryActionTriggered)
            
            if let fetchedObjects = self.hiddenUpdatesFetchedResultsController.fetchedObjects, !fetchedObjects.isEmpty
            {
                cell.textLabel.text = NSLocalizedString("Unsupported Updates Available", comment: "")
                cell.button.isHidden = false
            }
            else
            {
                cell.textLabel.text = NSLocalizedString("No Updates Available", comment: "")
                cell.button.isHidden = true
            }
        }
        
        return dynamicDataSource
    }
    
    func makeUpdatesDataSource() -> RSTFetchedResultsCollectionViewPrefetchingDataSource<InstalledApp, UIImage>
    {
        let fetchRequest = InstalledApp.supportedUpdatesFetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \InstalledApp.storeApp?.latestSupportedVersion?.date, ascending: false),
                                        NSSortDescriptor(keyPath: \InstalledApp.name, ascending: true)]
        fetchRequest.returnsObjectsAsFaults = false
        
        let dataSource = RSTFetchedResultsCollectionViewPrefetchingDataSource<InstalledApp, UIImage>(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.viewContext)
        dataSource.liveFetchLimit = maximumCollapsedUpdatesCount
        dataSource.cellIdentifierHandler = { _ in "UpdateCell" }
        dataSource.cellConfigurationHandler = { [weak self] (cell, installedApp, indexPath) in
            guard let self = self else { return }
            guard let app = installedApp.storeApp, let latestSupportedVersion = app.latestSupportedVersion else { return }
            
            let cell = cell as! UpdateCollectionViewCell
            cell.layoutMargins.left = self.view.layoutMargins.left
            cell.layoutMargins.right = self.view.layoutMargins.right
            
            cell.tintColor = app.tintColor ?? .altPrimary
            cell.versionDescriptionTextView.text = latestSupportedVersion.localizedDescription
            
            cell.bannerView.iconImageView.image = nil
            cell.bannerView.iconImageView.isIndicatingActivity = true
            
            cell.bannerView.configure(for: app)
            
            let versionDate = Date().relativeDateString(since: latestSupportedVersion.date, dateFormatter: self.dateFormatter)
            cell.bannerView.subtitleLabel.text = versionDate
            
            let appName: String
            
            if app.isBeta
            {
                appName = String(format: NSLocalizedString("%@ beta", comment: ""), app.name)
            }
            else
            {
                appName = app.name
            }
            
            cell.bannerView.accessibilityLabel = String(format: NSLocalizedString("%@ %@ update. Released on %@.", comment: ""), appName, latestSupportedVersion.version, versionDate)
            
            cell.bannerView.button.isIndicatingActivity = false
            cell.bannerView.button.addTarget(self, action: #selector(MyAppsViewController.updateApp(_:)), for: .primaryActionTriggered)
            cell.bannerView.button.accessibilityLabel = String(format: NSLocalizedString("Update %@", comment: ""), installedApp.name)
            
            if self.expandedAppUpdates.contains(app.bundleIdentifier)
            {
                cell.mode = .expanded
            }
            else
            {
                cell.mode = .collapsed
            }
            
            cell.versionDescriptionTextView.moreButton.addTarget(self, action: #selector(MyAppsViewController.toggleUpdateCellMode(_:)), for: .primaryActionTriggered)
            
            let progress = AppManager.shared.installationProgress(for: app)
            cell.bannerView.button.progress = progress
            
            cell.setNeedsLayout()
        }
        dataSource.prefetchHandler = { (installedApp, indexPath, completionHandler) in
            guard let iconURL = installedApp.storeApp?.iconURL else { return nil }
            
            return RSTAsyncBlockOperation() { (operation) in
                ImagePipeline.shared.loadImage(with: iconURL, progress: nil, completion: { (response, error) in
                    guard !operation.isCancelled else { return operation.finish() }
                    
                    if let image = response?.image
                    {
                        completionHandler(image, nil)
                    }
                    else
                    {
                        completionHandler(nil, error)
                    }
                })
            }
        }
        dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            let cell = cell as! UpdateCollectionViewCell
            cell.bannerView.iconImageView.isIndicatingActivity = false
            cell.bannerView.iconImageView.image = image
            
            if let error = error
            {
                print("Error loading image:", error)
            }
        }
        
        return dataSource
    }
    
    func makeActiveAppsDataSource() -> RSTFetchedResultsCollectionViewPrefetchingDataSource<InstalledApp, UIImage>
    {
        let fetchRequest = InstalledApp.activeAppsFetchRequest()
        fetchRequest.relationshipKeyPathsForPrefetching = [#keyPath(InstalledApp.storeApp)]
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \InstalledApp.expirationDate, ascending: true),
                                        NSSortDescriptor(keyPath: \InstalledApp.refreshedDate, ascending: false),
                                        NSSortDescriptor(keyPath: \InstalledApp.name, ascending: true)]
        fetchRequest.returnsObjectsAsFaults = false
        
        let dataSource = RSTFetchedResultsCollectionViewPrefetchingDataSource<InstalledApp, UIImage>(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.viewContext)
        dataSource.cellIdentifierHandler = { _ in "AppCell" }
        dataSource.cellConfigurationHandler = { (cell, installedApp, indexPath) in
            let tintColor = installedApp.storeApp?.tintColor ?? .altPrimary
            
            let cell = cell as! InstalledAppCollectionViewCell
            cell.layoutMargins.left = self.view.layoutMargins.left
            cell.layoutMargins.right = self.view.layoutMargins.right
            cell.tintColor = tintColor
            
            cell.deactivateBadge?.isHidden = false
            
            if let dropIndexPath = self.dropDestinationIndexPath, dropIndexPath.section == Section.activeApps.rawValue && dropIndexPath.item == indexPath.item
            {
                cell.bannerView.alpha = 0.4
                
                cell.deactivateBadge?.alpha = 1.0
                cell.deactivateBadge?.transform = .identity
            }
            else
            {
                cell.bannerView.alpha = 1.0
                
                cell.deactivateBadge?.alpha = 0.0
                cell.deactivateBadge?.transform = CGAffineTransform.identity.scaledBy(x: 0.33, y: 0.33)
            }
            
            cell.bannerView.configure(for: installedApp)
            
            cell.bannerView.iconImageView.isIndicatingActivity = true
            
            cell.bannerView.buttonLabel.isHidden = false
            cell.bannerView.buttonLabel.text = NSLocalizedString("Expires in", comment: "")
            
            cell.bannerView.button.isIndicatingActivity = false
            cell.bannerView.button.removeTarget(self, action: nil, for: .primaryActionTriggered)
            cell.bannerView.button.addTarget(self, action: #selector(MyAppsViewController.refreshApp(_:)), for: .primaryActionTriggered)
            
            let currentDate = Date()
            
            let numberOfDays = installedApp.expirationDate.numberOfCalendarDays(since: currentDate)
            let numberOfDaysText: String
            
            if numberOfDays == 1
            {
                numberOfDaysText = NSLocalizedString("1 day", comment: "")
            }
            else
            {
                numberOfDaysText = String(format: NSLocalizedString("%@ days", comment: ""), NSNumber(value: numberOfDays))
            }
            
            cell.bannerView.button.setTitle(numberOfDaysText.uppercased(), for: .normal)
            cell.bannerView.button.accessibilityLabel = String(format: NSLocalizedString("Refresh %@", comment: ""), installedApp.name)
            
            cell.bannerView.accessibilityLabel? += ". " + String(format: NSLocalizedString("Expires in %@", comment: ""), numberOfDaysText)
            
            // Make sure refresh button is correct size.
            cell.layoutIfNeeded()
            
            switch numberOfDays
            {
            case 2...3: cell.bannerView.button.tintColor = .refreshOrange
            case 4...5: cell.bannerView.button.tintColor = .refreshYellow
            case 6...: cell.bannerView.button.tintColor = .refreshGreen
            default: cell.bannerView.button.tintColor = .refreshRed
            }
            
            if let progress = AppManager.shared.refreshProgress(for: installedApp), progress.fractionCompleted < 1.0
            {
                cell.bannerView.button.progress = progress
            }
            else
            {
                cell.bannerView.button.progress = nil
            }
        }
        dataSource.prefetchHandler = { (item, indexPath, completion) in
            RSTAsyncBlockOperation { (operation) in
                item.managedObjectContext?.perform {
                    item.loadIcon { (result) in
                        switch result
                        {
                        case .failure(let error): completion(nil, error)
                        case .success(let image): completion(image, nil)
                        }
                    }
                }
            }
        }
        dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            let cell = cell as! InstalledAppCollectionViewCell
            cell.bannerView.iconImageView.image = image
            cell.bannerView.iconImageView.isIndicatingActivity = false
        }
        
        return dataSource
    }
    
    func makeInactiveAppsDataSource() -> RSTFetchedResultsCollectionViewPrefetchingDataSource<InstalledApp, UIImage>
    {
        let fetchRequest = InstalledApp.fetchRequest() as NSFetchRequest<InstalledApp>
        fetchRequest.relationshipKeyPathsForPrefetching = [#keyPath(InstalledApp.storeApp)]
        fetchRequest.predicate = NSPredicate(format: "%K == NO", #keyPath(InstalledApp.isActive))
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \InstalledApp.expirationDate, ascending: true),
                                        NSSortDescriptor(keyPath: \InstalledApp.refreshedDate, ascending: false),
                                        NSSortDescriptor(keyPath: \InstalledApp.name, ascending: true)]
        fetchRequest.returnsObjectsAsFaults = false
        
        let dataSource = RSTFetchedResultsCollectionViewPrefetchingDataSource<InstalledApp, UIImage>(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.viewContext)
        dataSource.cellIdentifierHandler = { _ in "AppCell" }
        dataSource.cellConfigurationHandler = { (cell, installedApp, indexPath) in
            let tintColor = installedApp.storeApp?.tintColor ?? .altPrimary
            
            let cell = cell as! InstalledAppCollectionViewCell
            cell.layoutMargins.left = self.view.layoutMargins.left
            cell.layoutMargins.right = self.view.layoutMargins.right
            cell.tintColor = UIColor.gray
            
            cell.bannerView.iconImageView.isIndicatingActivity = true
            cell.bannerView.buttonLabel.isHidden = true
            cell.bannerView.alpha = 1.0
            
            cell.deactivateBadge?.isHidden = true
            cell.deactivateBadge?.alpha = 0.0
            cell.deactivateBadge?.transform = CGAffineTransform.identity.scaledBy(x: 0.5, y: 0.5)
            
            cell.bannerView.configure(for: installedApp)
            
            cell.bannerView.button.isIndicatingActivity = false
            cell.bannerView.button.tintColor = tintColor
            cell.bannerView.button.setTitle(NSLocalizedString("ACTIVATE", comment: ""), for: .normal)
            cell.bannerView.button.removeTarget(self, action: nil, for: .primaryActionTriggered)
            cell.bannerView.button.addTarget(self, action: #selector(MyAppsViewController.activateApp(_:)), for: .primaryActionTriggered)
            cell.bannerView.button.accessibilityLabel = String(format: NSLocalizedString("Activate %@", comment: ""), installedApp.name)
            
            // Make sure refresh button is correct size.
            cell.layoutIfNeeded()
            
            // Ensure no leftover progress from active apps cell reuse.
            cell.bannerView.button.progress = nil
            
            if let progress = AppManager.shared.refreshProgress(for: installedApp), progress.fractionCompleted < 1.0
            {
                cell.bannerView.button.progress = progress
            }
            else
            {
                cell.bannerView.button.progress = nil
            }
        }
        dataSource.prefetchHandler = { (item, indexPath, completion) in
            RSTAsyncBlockOperation { (operation) in
                item.managedObjectContext?.perform {
                    item.loadIcon { (result) in
                        switch result
                        {
                        case .failure(let error): completion(nil, error)
                        case .success(let image): completion(image, nil)
                        }
                    }
                }
            }
        }
        dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            let cell = cell as! InstalledAppCollectionViewCell
            cell.bannerView.iconImageView.image = image
            cell.bannerView.iconImageView.isIndicatingActivity = false
        }
        
        return dataSource
    }
    
    func makeHiddenUpdatesFetchedResultsController() -> NSFetchedResultsController<InstalledApp>
    {
        let fetchRequest = InstalledApp.updatesFetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \InstalledApp.bundleIdentifier, ascending: true),
                                        NSSortDescriptor(keyPath: \InstalledApp.storeApp?.sourceIdentifier, ascending: true)] // Sorting doesn't matter as long as it's stable.
        
        let fetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.viewContext, sectionNameKeyPath: nil, cacheName: nil)
        return fetchedResultsController
    }
    
    func updateDataSource()
    {
        do
        {
            if self.updatesDataSource.fetchedResultsController.fetchedObjects == nil
            {
                try self.updatesDataSource.fetchedResultsController.performFetch()
            }
            
            if self.hiddenUpdatesFetchedResultsController.fetchedObjects == nil
            {
                try self.hiddenUpdatesFetchedResultsController.performFetch()
            }
        }
        catch
        {
            print("[ALTLog] Failed to fetch updates:", error)
        }
        
        if let patreonAccount = DatabaseManager.shared.patreonAccount(), patreonAccount.isPatron, PatreonAPI.shared.isAuthenticated
        {
            self.dataSource.predicate = nil
        }
        else
        {
            self.dataSource.predicate = NSPredicate(format: "%K == nil OR %K == NO OR %K == %@",
                                                    #keyPath(InstalledApp.storeApp),
                                                    #keyPath(InstalledApp.storeApp.isBeta),
                                                    #keyPath(InstalledApp.bundleIdentifier), StoreApp.altstoreAppID)
        }
    }
}

private extension MyAppsViewController
{
    func update()
    {
        do
        {
            try self.hiddenUpdatesFetchedResultsController.performFetch()
            try self.updatesDataSource.fetchedResultsController.performFetch()
        }
        catch
        {
            print("[ALTLog] Failed to fetch updates:", error)
        }
        
        if self.updatesDataSource.itemCount > 0
        {
            self.navigationController?.tabBarItem.badgeValue = String(describing: self.updatesDataSource.itemCount)
            UIApplication.shared.applicationIconBadgeNumber = Int(self.updatesDataSource.itemCount)
        }
        else
        {
            self.navigationController?.tabBarItem.badgeValue = nil
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
    
    func fetchAppIDs()
    {
        AppManager.shared.fetchAppIDs { (result) in
            do
            {
                let (_, context) = try result.get()
                try context.save()
            }
            catch
            {
                print("Failed to fetch App IDs.", error)
            }
        }
    }
    
    func refresh(_ installedApps: [InstalledApp], completionHandler: @escaping ([String : Result<InstalledApp, Error>]) -> Void)
    {
        let group = AppManager.shared.refresh(installedApps, presentingViewController: self, group: self.refreshGroup)
        group.completionHandler = { (results) in
            DispatchQueue.main.async {
                let failures = results.compactMapValues { (result) -> Error? in
                    switch result
                    {
                    case .failure(OperationError.cancelled): return nil
                    case .failure(let error): return error
                    case .success: return nil
                    }
                }
                
                guard !failures.isEmpty else { return }
                
                let toastView: ToastView
                
                if let failure = failures.first, results.count == 1
                {
                    toastView = ToastView(error: failure.value)
                }
                else
                {
                    let localizedText: String
                    
                    if failures.count == 1
                    {
                        localizedText = NSLocalizedString("Failed to refresh 1 app.", comment: "")
                    }
                    else
                    {
                        localizedText = String(format: NSLocalizedString("Failed to refresh %@ apps.", comment: ""), NSNumber(value: failures.count))
                    }
                    
                    let error = failures.first?.value as NSError?
                    let detailText = error?.localizedFailure ?? error?.localizedFailureReason ?? error?.localizedDescription
                    
                    toastView = ToastView(text: localizedText, detailText: detailText)
                    toastView.preferredDuration = 4.0
                }
                
                toastView.opensErrorLog = true
                
                toastView.show(in: self)
            }
            
            self.refreshGroup = nil
            completionHandler(results)
        }
        
        self.refreshGroup = group
        
        UIView.performWithoutAnimation {
            self.collectionView.reloadSections([Section.activeApps.rawValue, Section.inactiveApps.rawValue])
        }
    }
}

private extension MyAppsViewController
{
    @IBAction func toggleAppUpdates(_ sender: UIButton)
    {
        let visibleCells = self.collectionView.visibleCells
        
        self.collectionView.performBatchUpdates({
            
            self.isUpdateSectionCollapsed.toggle()
            
            UIView.animate(withDuration: 0.3, animations: {
                if self.isUpdateSectionCollapsed
                {
                    self.updatesDataSource.liveFetchLimit = maximumCollapsedUpdatesCount
                    self.expandedAppUpdates.removeAll()
                    
                    for case let cell as UpdateCollectionViewCell in visibleCells
                    {
                        cell.mode = .collapsed
                    }
                    
                    self.cachedUpdateSizes.removeAll()
                    
                    sender.titleLabel?.transform = .identity
                }
                else
                {
                    self.updatesDataSource.liveFetchLimit = 0
                    
                    sender.titleLabel?.transform = CGAffineTransform.identity.rotated(by: .pi)
                }
            })
            
            self.collectionView.collectionViewLayout.invalidateLayout()
            
        }, completion: nil)
    }
    
    @IBAction func toggleUpdateCellMode(_ sender: UIButton)
    {
        let point = self.collectionView.convert(sender.center, from: sender.superview)
        guard let indexPath = self.collectionView.indexPathForItem(at: point) else { return }
        
        let installedApp = self.dataSource.item(at: indexPath)
        
        let cell = self.collectionView.cellForItem(at: indexPath) as? UpdateCollectionViewCell
        
        if self.expandedAppUpdates.contains(installedApp.bundleIdentifier)
        {
            self.expandedAppUpdates.remove(installedApp.bundleIdentifier)
            cell?.mode = .collapsed
        }
        else
        {
            self.expandedAppUpdates.insert(installedApp.bundleIdentifier)
            cell?.mode = .expanded
        }
        
        self.cachedUpdateSizes[installedApp.bundleIdentifier] = nil
        
        self.collectionView.performBatchUpdates({
            self.collectionView.collectionViewLayout.invalidateLayout()
        }, completion: nil)
    }
    
    @IBAction func refreshApp(_ sender: UIButton)
    {
        let point = self.collectionView.convert(sender.center, from: sender.superview)
        guard let indexPath = self.collectionView.indexPathForItem(at: point) else { return }
        
        let installedApp = self.dataSource.item(at: indexPath)
        self.refresh(installedApp)
    }
    
    @IBAction func refreshAllApps(_ sender: UIBarButtonItem)
    {
        self.isRefreshingAllApps = true
        self.collectionView.collectionViewLayout.invalidateLayout()

        let installedApps = InstalledApp.fetchAppsForRefreshingAll(in: DatabaseManager.shared.viewContext)
        
        self.refresh(installedApps) { (result) in
            DispatchQueue.main.async {
                self.isRefreshingAllApps = false
                self.collectionView.reloadSections([Section.activeApps.rawValue, Section.inactiveApps.rawValue])
            }
        }
        
        if #available(iOS 14, *)
        {
            let interaction = INInteraction.refreshAllApps()
            interaction.donate { (error) in
                guard let error = error else { return }
                print("Failed to donate intent \(interaction.intent).", error)
            }
        }
    }
    
    @IBAction func updateApp(_ sender: UIButton)
    {
        let point = self.collectionView.convert(sender.center, from: sender.superview)
        guard let indexPath = self.collectionView.indexPathForItem(at: point) else { return }
        
        let installedApp = self.dataSource.item(at: indexPath)
        
        let previousProgress = AppManager.shared.installationProgress(for: installedApp)
        guard previousProgress == nil else {
            previousProgress?.cancel()
            return
        }
        
        _ = AppManager.shared.update(installedApp, presentingViewController: self) { (result) in
            DispatchQueue.main.async {
                switch result
                {
                case .failure(OperationError.cancelled):
                    self.collectionView.reloadItems(at: [indexPath])
                    
                case .failure(let error):
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)
                    
                    self.collectionView.reloadItems(at: [indexPath])
                    
                case .success:
                    print("Updated app:", installedApp.bundleIdentifier)
                    // No need to reload, since the the update cell is gone now.
                }
                
                self.update()
            }
        }
        
        self.collectionView.reloadItems(at: [indexPath])
    }
    
    @IBAction func sideloadApp(_ sender: UIBarButtonItem)
    {
        let supportedTypes: [String]
        
        if let types = UTTypeCreateAllIdentifiersForTag(kUTTagClassFilenameExtension, "ipa" as CFString, nil)?.takeRetainedValue()
        {
            supportedTypes = (types as NSArray).map { $0 as! String }
        }
        else
        {
            supportedTypes = ["com.apple.itunes.ipa"] // Declared by the system.
        }
        
        let documentPickerViewController = UIDocumentPickerViewController(documentTypes: supportedTypes, in: .import)
        documentPickerViewController.delegate = self
        self.present(documentPickerViewController, animated: true, completion: nil)
    }
    
    func sideloadApp(at url: URL, completion: @escaping (Result<Void, Error>) -> Void)
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        self.navigationItem.leftBarButtonItem?.isIndicatingActivity = true
        
        class Context
        {
            var fileURL: URL?
            var application: ALTApplication?
            var installedApp: InstalledApp? {
                didSet {
                    self.installedAppContext = self.installedApp?.managedObjectContext
                }
            }
            private var installedAppContext: NSManagedObjectContext?
            
            var error: Error?
        }
        
        let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
        let unzippedAppDirectory = temporaryDirectory.appendingPathComponent("App")
        
        let context = Context()
        
        let downloadOperation: RSTAsyncBlockOperation?
        
        if url.isFileURL
        {
            downloadOperation = nil
            context.fileURL = url
            progress.totalUnitCount -= 20
        }
        else
        {
            let downloadProgress = Progress.discreteProgress(totalUnitCount: 100)
            downloadOperation = RSTAsyncBlockOperation { (operation) in
                let downloadTask = URLSession.shared.downloadTask(with: url) { (fileURL, response, error) in
                    do
                    {
                        let (fileURL, _) = try Result((fileURL, response), error).get()
                        
                        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
                        
                        let destinationURL = temporaryDirectory.appendingPathComponent("App.ipa")
                        try FileManager.default.moveItem(at: fileURL, to: destinationURL)
                        
                        context.fileURL = destinationURL
                    }
                    catch
                    {
                        context.error = error
                    }
                    operation.finish()
                }
                downloadProgress.addChild(downloadTask.progress, withPendingUnitCount: 100)
                downloadTask.resume()
            }
            progress.addChild(downloadProgress, withPendingUnitCount: 20)
        }
        
        let unzipProgress = Progress.discreteProgress(totalUnitCount: 1)
        let unzipAppOperation = BlockOperation {
            do
            {
                if let error = context.error
                {
                    throw error
                }
                
                guard let fileURL = context.fileURL else { throw OperationError.invalidParameters }
                defer {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                
                try FileManager.default.createDirectory(at: unzippedAppDirectory, withIntermediateDirectories: true, attributes: nil)
                let unzippedApplicationURL = try FileManager.default.unzipAppBundle(at: fileURL, toDirectory: unzippedAppDirectory)
                
                guard let application = ALTApplication(fileURL: unzippedApplicationURL) else { throw OperationError.invalidApp }
                context.application = application
                
                unzipProgress.completedUnitCount = 1
            }
            catch
            {
                context.error = error
            }
        }
        progress.addChild(unzipProgress, withPendingUnitCount: 10)
        
        if let downloadOperation = downloadOperation
        {
            unzipAppOperation.addDependency(downloadOperation)
        }
        
        let removeAppExtensionsProgress = Progress.discreteProgress(totalUnitCount: 1)
        let removeAppExtensionsOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            do
            {
                if let error = context.error
                {
                    throw error
                }
                
                guard let application = context.application else { throw OperationError.invalidParameters }
                
                DispatchQueue.main.async {
                    self?.removeAppExtensions(from: application) { (result) in
                        switch result
                        {
                        case .success: removeAppExtensionsProgress.completedUnitCount = 1
                        case .failure(let error): context.error = error
                        }
                        operation.finish()
                    }
                }
            }
            catch
            {
                context.error = error
                operation.finish()
            }
        }
        removeAppExtensionsOperation.addDependency(unzipAppOperation)
        progress.addChild(removeAppExtensionsProgress, withPendingUnitCount: 5)
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        let installAppOperation = RSTAsyncBlockOperation { (operation) in
            do
            {
                if let error = context.error
                {
                    throw error
                }
                
                guard let application = context.application else { throw OperationError.invalidParameters }
                
                let group = AppManager.shared.install(application, presentingViewController: self) { (result) in
                    switch result
                    {
                    case .success(let installedApp): context.installedApp = installedApp
                    case .failure(let error): context.error = error
                    }
                    operation.finish()
                }
                installProgress.addChild(group.progress, withPendingUnitCount: 100)
            }
            catch
            {
                context.error = error
                operation.finish()
            }
        }
        installAppOperation.completionBlock = {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            
            DispatchQueue.main.async {
                self.navigationItem.leftBarButtonItem?.isIndicatingActivity = false
                self.sideloadingProgressView.observedProgress = nil
                self.sideloadingProgressView.setHidden(true, animated: true)
                
                switch Result(context.installedApp, context.error)
                {
                case .success(let app):
                    completion(.success(()))
                    
                    app.managedObjectContext?.perform {
                        print("Successfully installed app:", app.bundleIdentifier)
                    }
                    
                case .failure(OperationError.cancelled):
                    completion(.failure((OperationError.cancelled)))
                    
                case .failure(let error):
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)
                    
                    completion(.failure(error))
                }
            }
        }
        progress.addChild(installProgress, withPendingUnitCount: 65)
        installAppOperation.addDependency(removeAppExtensionsOperation)
        
        self.sideloadingProgress = progress
        self.sideloadingProgressView.progress = 0
        self.sideloadingProgressView.isHidden = false
        self.sideloadingProgressView.observedProgress = self.sideloadingProgress
        
        let operations = [downloadOperation, unzipAppOperation, removeAppExtensionsOperation, installAppOperation].compactMap { $0 }
        self.operationQueue.addOperations(operations, waitUntilFinished: false)
    }
    
    @IBAction func activateApp(_ sender: UIButton)
    {
        let point = self.collectionView.convert(sender.center, from: sender.superview)
        guard let indexPath = self.collectionView.indexPathForItem(at: point) else { return }
        
        let installedApp = self.dataSource.item(at: indexPath)
        self.activate(installedApp)
    }
    
    @IBAction func deactivateApp(_ sender: UIButton)
    {
        let point = self.collectionView.convert(sender.center, from: sender.superview)
        guard let indexPath = self.collectionView.indexPathForItem(at: point) else { return }
        
        let installedApp = self.dataSource.item(at: indexPath)
        self.deactivate(installedApp)
    }
    
    @objc func presentInactiveAppsAlert()
    {
        var message: String
        
        if UserDefaults.standard.activeAppLimitIncludesExtensions
        {
            message = NSLocalizedString("Non-developer Apple IDs are limited to 3 apps and app extensions. Inactive apps don't count towards your total, but cannot be opened until activated.", comment: "")
        }
        else
        {
            message = NSLocalizedString("Non-developer Apple IDs are limited to 3 apps. Inactive apps are backed up and uninstalled so they don't count towards your total, but will be reinstalled with all their data when activated again.", comment: "")
            
            if UserDefaults.standard.ignoreActiveAppsLimit
            {
                message += "\n\n"
                message += NSLocalizedString("If you're using the MacDirtyCow exploit to remove the 3-app limit, you can install up to 10 apps and app extensions instead.", comment: "")
            }
        }
                
        let alertController = UIAlertController(title: NSLocalizedString("What are inactive apps?", comment: ""), message: message, preferredStyle: .alert)
        alertController.addAction(.ok)
        self.present(alertController, animated: true, completion: nil)
    }
    
    func updateCell(at indexPath: IndexPath)
    {
        guard let cell = collectionView.cellForItem(at: indexPath) as? InstalledAppCollectionViewCell else { return }
        
        let installedApp = self.dataSource.item(at: indexPath)
        self.dataSource.cellConfigurationHandler(cell, installedApp, indexPath)
        
        cell.bannerView.iconImageView.isIndicatingActivity = false
    }
    
    func removeAppExtensions(from application: ALTApplication, completion: @escaping (Result<Void, Error>) -> Void)
    {
        guard !application.appExtensions.isEmpty else { return completion(.success(())) }
        
        func removeAppExtensions() throws
        {
            for appExtension in application.appExtensions
            {
                try FileManager.default.removeItem(at: appExtension.fileURL)
            }
            
            let scInfoURL = application.fileURL.appendingPathComponent("SC_Info")
            let manifestPlistURL = scInfoURL.appendingPathComponent("Manifest.plist")
            
            if let manifestPlist = NSMutableDictionary(contentsOf: manifestPlistURL),
               let sinfReplicationPaths = manifestPlist["SinfReplicationPaths"] as? [String]
            {
                let replacementPaths = sinfReplicationPaths.filter { !$0.starts(with: "PlugIns/") } // Filter out app extension paths.
                manifestPlist["SinfReplicationPaths"] = replacementPaths
                try manifestPlist.write(to: manifestPlistURL)
            }
        }
        
        let firstSentence: String
        
        if UserDefaults.standard.activeAppLimitIncludesExtensions
        {
            firstSentence = NSLocalizedString("Non-developer Apple IDs are limited to 3 active apps and app extensions.", comment: "")
        }
        else
        {
            firstSentence = NSLocalizedString("Non-developer Apple IDs are limited to creating 10 App IDs per week.", comment: "")
        }
        
        let message = firstSentence + " " + NSLocalizedString("Would you like to remove this app's extensions so they don't count towards your limit?", comment: "")
        
        let alertController = UIAlertController(title: NSLocalizedString("App Contains Extensions", comment: ""), message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style, handler: { (action) in
            completion(.failure(OperationError.cancelled))
        }))
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Keep App Extensions", comment: ""), style: .default) { (action) in
            completion(.success(()))
        })
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Remove App Extensions", comment: ""), style: .destructive) { (action) in
            let result = Result { try removeAppExtensions() }
            completion(result)
        })
        
        self.present(alertController, animated: true, completion: nil)
    }
    
    @objc func showHiddenUpdatesAlert(_ sender: UIButton)
    {
        guard let installedApps = self.hiddenUpdatesFetchedResultsController.fetchedObjects, !installedApps.isEmpty, self.updatesDataSource.itemCount == 0 else { return }
        
        let numberOfHiddenUpdates = installedApps.count
        
        let title = numberOfHiddenUpdates == 1 ? NSLocalizedString("Unsupported Update Available", comment: "") : String(format: NSLocalizedString("%@ Unsupported Updates Available", comment: ""), numberOfHiddenUpdates as NSNumber)
        var message = String(format: NSLocalizedString("These updates don't support iOS %@. Please update your device to the latest iOS version to install them.", comment: ""), ProcessInfo.processInfo.operatingSystemVersion.stringValue)
        message += "\n"
        
        for installedApp in installedApps
        {
            guard let storeApp = installedApp.storeApp else { continue }
            
            var title = storeApp.name
            if let appVersion = storeApp.latestAvailableVersion
            {
                title += " " + appVersion.version
                
                var osVersion: String? = nil
                if let minOSVersion = appVersion.minOSVersion, !ProcessInfo.processInfo.isOperatingSystemAtLeast(minOSVersion)
                {
                    osVersion = String(format: NSLocalizedString("iOS %@ or later", comment: ""), minOSVersion.stringValue)
                }
                else if let maxOSVersion = appVersion.maxOSVersion, ProcessInfo.processInfo.operatingSystemVersion > maxOSVersion
                {
                    osVersion = String(format: NSLocalizedString("iOS %@ or earlier", comment: ""), maxOSVersion.stringValue)
                }
                
                if let osVersion
                {
                    title += " (" + osVersion + ")"
                }
            }
            
            message += "\n" + title
        }
        
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(.ok)
        
        self.present(alertController, animated: true)
    }
}

private extension MyAppsViewController
{
    func open(_ installedApp: InstalledApp)
    {
        UIApplication.shared.open(installedApp.openAppURL) { success in
            guard !success else { return }
            
            let toastView = ToastView(error: OperationError.openAppFailed(name: installedApp.name))
            toastView.show(in: self)
        }
    }
    
    func refresh(_ installedApp: InstalledApp)
    {
        let previousProgress = AppManager.shared.refreshProgress(for: installedApp)
        guard previousProgress == nil else {
            previousProgress?.cancel()
            return
        }
        
        self.refresh([installedApp]) { (results) in
            // If an error occured, reload the section so the progress bar is no longer visible.
            if results.values.contains(where: { $0.error != nil })
            {
                DispatchQueue.main.async {
                    self.collectionView.reloadSections([Section.activeApps.rawValue, Section.inactiveApps.rawValue])
                }
            }
            
            print("Finished refreshing with results:", results.map { ($0, $1.error?.localizedDescription ?? "success") })
        }
    }
    
    func activate(_ installedApp: InstalledApp)
    {
        func finish(_ result: Result<InstalledApp, Error>)
        {
            do
            {
                let app = try result.get()
                app.managedObjectContext?.perform {
                    try? app.managedObjectContext?.save()
                }
            }
            catch OperationError.cancelled
            {
                // Ignore
            }
            catch
            {
                print("Failed to activate app:", error)
                
                DispatchQueue.main.async {
                    installedApp.isActive = false
                    
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)
                }
            }
        }
                
        if UserDefaults.standard.activeAppsLimit != nil, #available(iOS 13, *)
        {
            // UserDefaults.standard.activeAppsLimit is only non-nil on iOS 13.3.1 or later, so the #available check is just so we can use Combine.
            
            guard let app = ALTApplication(fileURL: installedApp.fileURL) else { return finish(.failure(OperationError.invalidApp)) }
            
            var cancellable: AnyCancellable?
            cancellable = DatabaseManager.shared.viewContext.registeredObjects.publisher
                .compactMap { $0 as? InstalledApp }
                .filter(\.isActive)
                .map { $0.publisher(for: \.isActive) }
                .collect()
                .flatMap { publishers in
                    Publishers.MergeMany(publishers)
                }
                .first { isActive in !isActive }
                .sink { _ in
                    // A previously active app is now inactive,
                    // which means there are now enough slots to activate the app,
                    // so pre-emptively mark it as active to provide visual feedback sooner.
                    installedApp.isActive = true
                    cancellable?.cancel()
                }
            
            AppManager.shared.deactivateApps(for: app, presentingViewController: self) { result in
                cancellable?.cancel()
                installedApp.managedObjectContext?.perform {
                    switch result
                    {
                    case .failure(let error):
                        installedApp.isActive = false
                        finish(.failure(error))
                        
                    case .success:
                        installedApp.isActive = true
                        AppManager.shared.activate(installedApp, presentingViewController: self, completionHandler: finish(_:))
                    }
                }
            }
        }
        else
        {
            installedApp.isActive = true
            AppManager.shared.activate(installedApp, presentingViewController: self, completionHandler: finish(_:))
        }
    }
    
    func deactivate(_ installedApp: InstalledApp, completionHandler: ((Result<InstalledApp, Error>) -> Void)? = nil)
    {
        guard installedApp.isActive else { return }
        installedApp.isActive = false
        
        AppManager.shared.deactivate(installedApp, presentingViewController: self) { (result) in
            do
            {
                let app = try result.get()
                try? app.managedObjectContext?.save()
                
                print("Finished deactivating app:", app.bundleIdentifier)
            }
            catch
            {
                print("Failed to deactivate app:", error)
                
                DispatchQueue.main.async {
                    installedApp.isActive = true
                    
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)
                }
            }
            
            completionHandler?(result)
        }
    }
    
    func remove(_ installedApp: InstalledApp)
    {
        let title = String(format: NSLocalizedString("Remove “%@” from AltStore?", comment: ""), installedApp.name)
        let message: String
        
        if UserDefaults.standard.isLegacyDeactivationSupported
        {
            message = NSLocalizedString("You must also delete it from the home screen to fully uninstall the app.", comment: "")
        }
        else
        {
            message = NSLocalizedString("This will also erase all backup data for this app.", comment: "")
        }

        let alertController = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Remove", comment: ""), style: .destructive, handler: { (action) in
            AppManager.shared.remove(installedApp) { (result) in
                switch result
                {
                case .success: break
                case .failure(let error):
                    DispatchQueue.main.async {
                        let toastView = ToastView(error: error)
                        toastView.opensErrorLog = true
                        toastView.show(in: self)
                    }
                }
            }
        }))
        
        self.present(alertController, animated: true, completion: nil)
    }
    
    func backup(_ installedApp: InstalledApp)
    {
        let title = NSLocalizedString("Start Backup?", comment: "")
        let message = NSLocalizedString("This will replace any previous backups. Please leave AltStore open until the backup is complete.", comment: "")

        let alertController = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        alertController.addAction(.cancel)
        
        let actionTitle = String(format: NSLocalizedString("Back Up %@", comment: ""), installedApp.name)
        alertController.addAction(UIAlertAction(title: actionTitle, style: .default, handler: { (action) in
            AppManager.shared.backup(installedApp, presentingViewController: self) { (result) in
                do
                {
                    let app = try result.get()
                    try? app.managedObjectContext?.save()
                    
                    print("Finished backing up app:", app.bundleIdentifier)
                }
                catch
                {
                    print("Failed to back up app:", error)
                    
                    DispatchQueue.main.async {
                        let toastView = ToastView(error: error)
                        toastView.opensErrorLog = true
                        toastView.show(in: self)
                        
                        self.collectionView.reloadSections([Section.activeApps.rawValue, Section.inactiveApps.rawValue])
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.collectionView.reloadSections([Section.activeApps.rawValue, Section.inactiveApps.rawValue])
            }
        }))
        
        self.present(alertController, animated: true, completion: nil)
    }
    
    func restore(_ installedApp: InstalledApp)
    {
        let message = String(format: NSLocalizedString("This will replace all data you currently have in %@.", comment: ""), installedApp.name)
        let alertController = UIAlertController(title: NSLocalizedString("Are you sure you want to restore this backup?", comment: ""), message: message, preferredStyle: .actionSheet)
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Restore Backup", comment: ""), style: .destructive, handler: { (action) in
            AppManager.shared.restore(installedApp, presentingViewController: self) { (result) in
                do
                {
                    let app = try result.get()
                    try? app.managedObjectContext?.save()
                    
                    print("Finished restoring app:", app.bundleIdentifier)
                }
                catch
                {
                    print("Failed to restore app:", error)
                    
                    DispatchQueue.main.async {
                        let toastView = ToastView(error: error)
                        toastView.opensErrorLog = true
                        toastView.show(in: self)
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.collectionView.reloadSections([Section.activeApps.rawValue])
            }
        }))
        
        self.present(alertController, animated: true, completion: nil)
    }
    
    func exportBackup(for installedApp: InstalledApp)
    {
        guard let backupURL = FileManager.default.backupDirectoryURL(for: installedApp) else { return }
        
        let documentPicker = UIDocumentPickerViewController(url: backupURL, in: .exportToService)
        documentPicker.delegate = self
        self.present(documentPicker, animated: true, completion: nil)
    }
    
    func chooseIcon(for installedApp: InstalledApp)
    {
        self._imagePickerInstalledApp = installedApp
        
        let imagePicker = UIImagePickerController()
        imagePicker.delegate = self
        imagePicker.allowsEditing = true
        self.present(imagePicker, animated: true, completion: nil)
    }
    
    func changeIcon(for installedApp: InstalledApp, to image: UIImage?)
    {
        // Remove previous icon from cache.
        self.activeAppsDataSource.prefetchItemCache.removeObject(forKey: installedApp)
        self.inactiveAppsDataSource.prefetchItemCache.removeObject(forKey: installedApp)
        
        DatabaseManager.shared.persistentContainer.performBackgroundTask { (context) in
            do
            {
                let tempApp = context.object(with: installedApp.objectID) as! InstalledApp
                tempApp.needsResign = true
                tempApp.hasAlternateIcon = (image != nil)
                
                if let image = image
                {
                    guard let icon = image.resizing(toFill: CGSize(width: 256, height: 256)),
                          let iconData = icon.pngData()
                    else { return }
                    
                    try iconData.write(to: tempApp.alternateIconURL, options: .atomic)
                }
                else
                {
                    try FileManager.default.removeItem(at: tempApp.alternateIconURL)
                }
                
                try context.save()
                
                if tempApp.isActive
                {
                    DispatchQueue.main.async {
                        self.refresh(installedApp)
                    }
                }
            }
            catch
            {
                print("Failed to change app icon.", error)
                
                DispatchQueue.main.async {
                    let toastView = ToastView(error: error)
                    toastView.show(in: self)
                }
            }
        }
    }
    
    @available(iOS 14, *)
    func enableJIT(for installedApp: InstalledApp)
    {
        AppManager.shared.enableJIT(for: installedApp) { result in
            DispatchQueue.main.async {
                switch result
                {
                case .success: break
                case .failure(let error):
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)
                }
            }
        }
    }
}

private extension MyAppsViewController
{
    @objc func didFetchSource(_ notification: Notification)
    {
        DispatchQueue.main.async {
            self.update()
        }
    }
    
    @objc func importApp(_ notification: Notification)
    {
        // Make sure left UIBarButtonItem has been set.
        self.loadViewIfNeeded()
        
        guard let url = notification.userInfo?[AppDelegate.importAppDeepLinkURLKey] as? URL else { return }
        
        self.sideloadApp(at: url) { (result) in
            guard url.isFileURL else { return }
            
            do
            {
                try FileManager.default.removeItem(at: url)
            }
            catch
            {
                print("Unable to remove imported .ipa.", error)
            }
        }
    }
    
    @objc func checkForUpdates(_ sender: UIRefreshControl)
    {
        guard !self.isCheckingForUpdates else { return }
        self.isCheckingForUpdates = true
        
        AppManager.shared.fetchSources() { (result) in
            do
            {
                do
                {
                    defer {
                        DispatchQueue.main.async {
                            self.isCheckingForUpdates = false
                            sender.endRefreshing()
                        }
                    }
                    
                    let (_, context) = try result.get()
                    try context.save()
                }
                catch let error as AppManager.FetchSourcesError
                {
                    try error.managedObjectContext?.save()
                    throw error
                }
                catch let mergeError as MergeError
                {
                    guard let sourceID = mergeError.sourceID else { throw mergeError }
                    
                    let sanitizedError = (mergeError as NSError).sanitizedForSerialization()
                    DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                        do
                        {
                            guard let source = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), sourceID), in: context) else { return }
                            
                            source.error = sanitizedError
                            try context.save()
                        }
                        catch
                        {
                            print("[ALTLog] Failed to assign error \(sanitizedError.localizedErrorCode) to source \(sourceID).", error)
                        }
                    }
                    
                    throw mergeError
                }
            }
            catch let error as NSError
            {
                DispatchQueue.main.async {
                    let toastView = ToastView(error: error.withLocalizedTitle(NSLocalizedString("Unable to Check for Updates", comment: "")))
                    toastView.addTarget(nil, action: #selector(TabBarController.presentSources), for: .touchUpInside)
                    toastView.show(in: self)
                }
            }
        }
    }
}

extension MyAppsViewController
{
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView
    {
        let section = Section(rawValue: indexPath.section)!
        
        switch section
        {
        case .noUpdates: return UICollectionReusableView()
        case .updates:
            let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "UpdatesHeader", for: indexPath) as! UpdatesCollectionHeaderView
            
            UIView.performWithoutAnimation {
                headerView.button.backgroundColor = UIColor.altPrimary.withAlphaComponent(0.15)
                headerView.button.setTitle("▾", for: .normal)
                headerView.button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 28)
                headerView.button.setTitleColor(.altPrimary, for: .normal)
                headerView.button.addTarget(self, action: #selector(MyAppsViewController.toggleAppUpdates), for: .primaryActionTriggered)
                
                if self.isUpdateSectionCollapsed
                {
                    headerView.button.titleLabel?.transform = .identity
                }
                else
                {
                    headerView.button.titleLabel?.transform = CGAffineTransform.identity.rotated(by: .pi)
                }
                
                headerView.isHidden = (self.updatesDataSource.itemCount <= 2)
                
                headerView.button.layoutIfNeeded()
            }
            
            return headerView
            
        case .activeApps where kind == UICollectionView.elementKindSectionHeader:
            let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "ActiveAppsHeader", for: indexPath) as! InstalledAppsCollectionHeaderView
            
            UIView.performWithoutAnimation {
                headerView.layoutMargins.left = self.view.layoutMargins.left
                headerView.layoutMargins.right = self.view.layoutMargins.right
                
                if UserDefaults.standard.activeAppsLimit == nil
                {
                    headerView.textLabel.text = NSLocalizedString("Installed", comment: "")
                }
                else
                {
                    headerView.textLabel.text = NSLocalizedString("Active", comment: "")
                }
                
                headerView.button.isIndicatingActivity = false
                headerView.button.activityIndicatorView.color = .altPrimary
                headerView.button.setTitle(NSLocalizedString("Refresh All", comment: ""), for: .normal)
                headerView.button.addTarget(self, action: #selector(MyAppsViewController.refreshAllApps(_:)), for: .primaryActionTriggered)
                
                headerView.button.layoutIfNeeded()
                
                if self.isRefreshingAllApps
                {
                    headerView.button.isIndicatingActivity = true
                    headerView.button.accessibilityLabel = NSLocalizedString("Refreshing", comment: "")
                    headerView.button.accessibilityTraits.remove(.notEnabled)
                }
                else
                {
                    headerView.button.isIndicatingActivity = false
                    headerView.button.accessibilityLabel = nil
                }
            }
            
            return headerView
            
        case .inactiveApps where kind == UICollectionView.elementKindSectionHeader:
            let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "InactiveAppsHeader", for: indexPath) as! InstalledAppsCollectionHeaderView
            
            UIView.performWithoutAnimation {
                headerView.layoutMargins.left = self.view.layoutMargins.left
                headerView.layoutMargins.right = self.view.layoutMargins.right
                
                headerView.textLabel.text = NSLocalizedString("Inactive", comment: "")
                headerView.button.setTitle(nil, for: .normal)
                
                if #available(iOS 13.0, *)
                {
                    headerView.button.setImage(UIImage(systemName: "questionmark.circle"), for: .normal)
                }
                
                headerView.button.addTarget(self, action: #selector(MyAppsViewController.presentInactiveAppsAlert), for: .primaryActionTriggered)
            }
            
            return headerView
            
        case .activeApps, .inactiveApps:
            let footerView = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "InstalledAppsFooter", for: indexPath) as! InstalledAppsCollectionFooterView
            
            guard let team = DatabaseManager.shared.activeTeam() else { return footerView }
            switch team.type
            {
            case .free:
                let registeredAppIDs = team.appIDs.count
                
                let maximumAppIDCount = 10
                let remainingAppIDs = max(maximumAppIDCount - registeredAppIDs, 0)
                
                if remainingAppIDs == 1
                {
                    footerView.textLabel.text = String(format: NSLocalizedString("1 App ID Remaining", comment: ""))
                }
                else
                {
                    footerView.textLabel.text = String(format: NSLocalizedString("%@ App IDs Remaining", comment: ""), NSNumber(value: remainingAppIDs))
                }
                
                footerView.textLabel.isHidden = false
                
            case .individual, .organization, .unknown: footerView.textLabel.isHidden = true
            @unknown default: break
            }
            
            return footerView
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
    {
        let section = Section.allCases[indexPath.section]
        switch section
        {
        case .updates:
            guard let cell = collectionView.cellForItem(at: indexPath) else { break }
            self.performSegue(withIdentifier: "showUpdate", sender: cell)
            
        default: break
        }
    }
}

@available(iOS 13.0, *)
extension MyAppsViewController
{
    private func actions(for installedApp: InstalledApp) -> [UIMenuElement]
    {
        var actions = [UIMenuElement]()
        
        let openAction = UIAction(title: NSLocalizedString("Open", comment: ""), image: UIImage(systemName: "arrow.up.forward.app")) { (action) in
            self.open(installedApp)
        }
        
        let openMenu = UIMenu(title: "", options: .displayInline, children: [openAction])
        
        let refreshAction = UIAction(title: NSLocalizedString("Refresh", comment: ""), image: UIImage(systemName: "arrow.clockwise")) { (action) in
            self.refresh(installedApp)
        }
        
        let activateAction = UIAction(title: NSLocalizedString("Activate", comment: ""), image: UIImage(systemName: "checkmark.circle")) { (action) in
            self.activate(installedApp)
        }
        
        let deactivateAction = UIAction(title: NSLocalizedString("Deactivate", comment: ""), image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { (action) in
            self.deactivate(installedApp)
        }
        
        let removeAction = UIAction(title: NSLocalizedString("Remove", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { (action) in
            self.remove(installedApp)
        }
        
        let jitAction = UIAction(title: NSLocalizedString("Enable JIT", comment: ""), image: UIImage(systemName: "bolt")) { (action) in
            guard #available(iOS 14, *) else { return }
            self.enableJIT(for: installedApp)
        }
        
        let backupAction = UIAction(title: NSLocalizedString("Back Up", comment: ""), image: UIImage(systemName: "doc.on.doc")) { (action) in
            self.backup(installedApp)
        }
        
        let exportBackupAction = UIAction(title: NSLocalizedString("Export Backup", comment: ""), image: UIImage(systemName: "arrow.up.doc")) { (action) in
            self.exportBackup(for: installedApp)
        }
        
        let restoreBackupAction = UIAction(title: NSLocalizedString("Restore Backup", comment: ""), image: UIImage(systemName: "arrow.down.doc")) { (action) in
            self.restore(installedApp)
        }
        
        let chooseIconAction = UIAction(title: NSLocalizedString("Photos", comment: ""), image: UIImage(systemName: "photo")) { (action) in
            self.chooseIcon(for: installedApp)
        }
        
        let removeIconAction = UIAction(title: NSLocalizedString("Remove Custom Icon", comment: ""), image: UIImage(systemName: "trash"), attributes: [.destructive]) { (action) in
            self.changeIcon(for: installedApp, to: nil)
        }
        
        var changeIconActions = [chooseIconAction]
        if installedApp.hasAlternateIcon
        {
            changeIconActions.append(removeIconAction)
        }
        
        let changeIconMenu = UIMenu(title: NSLocalizedString("Change Icon", comment: ""), image: UIImage(systemName: "photo"), children: changeIconActions)
        
        guard installedApp.bundleIdentifier != StoreApp.altstoreAppID else {
            #if BETA
            return [refreshAction, changeIconMenu]
            #else
            return [refreshAction]
            #endif
        }
        
        if installedApp.isActive
        {
            actions.append(openMenu)
            actions.append(refreshAction)
        }
        else
        {
            actions.append(activateAction)
        }
        
        if installedApp.isActive, #available(iOS 14, *)
        {
            actions.append(jitAction)
        }
        
        #if BETA
        actions.append(changeIconMenu)
        #endif
        
        if installedApp.isActive
        {
            actions.append(backupAction)
        }
        else if let _ = UTTypeCopyDeclaration(installedApp.installedAppUTI as CFString)?.takeRetainedValue() as NSDictionary?, !UserDefaults.standard.isLegacyDeactivationSupported
        {
            // Allow backing up inactive apps if they are still installed,
            // but on an iOS version that no longer supports legacy deactivation.
            // This handles edge case where you can't install more apps until you
            // delete some, but can't activate inactive apps again to back them up first.
            actions.append(backupAction)
        }
                
        if let backupDirectoryURL = FileManager.default.backupDirectoryURL(for: installedApp)
        {
            var backupExists = false
            var outError: NSError? = nil
            
            self.coordinator.coordinate(readingItemAt: backupDirectoryURL, options: [.withoutChanges], error: &outError) { (backupDirectoryURL) in
                #if DEBUG
                backupExists = true
                #else
                backupExists = FileManager.default.fileExists(atPath: backupDirectoryURL.path)
                #endif
            }
            
            if backupExists
            {
                actions.append(exportBackupAction)
                
                if installedApp.isActive
                {
                    actions.append(restoreBackupAction)
                }
            }
            else if let error = outError
            {
                print("Unable to check if backup exists:", error)
            }
        }
        
        if installedApp.isActive
        {
            actions.append(deactivateAction)
        }
        
        #if DEBUG
        
        if installedApp.bundleIdentifier != StoreApp.altstoreAppID
        {
            actions.append(removeAction)
        }
        
        #else
        
        if (UserDefaults.standard.legacySideloadedApps ?? []).contains(installedApp.bundleIdentifier)
        {
            // Legacy sideloaded app, so can't detect if it's deleted.
            actions.append(removeAction)
        }
        else if !UserDefaults.standard.isLegacyDeactivationSupported && !installedApp.isActive
        {
            // Inactive apps are actually deleted, so we need another way
            // for user to remove them from AltStore.
            actions.append(removeAction)
        }
        
        #endif
        
        return actions
    }
    
    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
    {
        let section = Section(rawValue: indexPath.section)!
        switch section
        {
        case .updates, .noUpdates: return nil
        case .activeApps, .inactiveApps:
            let installedApp = self.dataSource.item(at: indexPath)
            
            return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { (suggestedActions) -> UIMenu? in
                let actions = self.actions(for: installedApp)
                
                let menu = UIMenu(title: "", children: actions)
                return menu
            }
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview?
    {
        guard let indexPath = configuration.identifier as? NSIndexPath else { return nil }
        guard let cell = collectionView.cellForItem(at: indexPath as IndexPath) as? InstalledAppCollectionViewCell else { return nil }
        
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bannerView.bounds, cornerRadius: cell.bannerView.layer.cornerRadius)
        
        let preview = UITargetedPreview(view: cell.bannerView, parameters: parameters)
        return preview
    }
    
    override func collectionView(_ collectionView: UICollectionView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview?
    {
        return self.collectionView(collectionView, previewForHighlightingContextMenuWithConfiguration: configuration)
    }
}

extension MyAppsViewController: UICollectionViewDelegateFlowLayout
{
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize
    {
        let section = Section.allCases[indexPath.section]
        switch section
        {
        case .noUpdates:
            let size = CGSize(width: collectionView.bounds.width, height: 44)
            return size
            
        case .updates:
            let item = self.dataSource.item(at: indexPath)
            
            if let previousHeight = self.cachedUpdateSizes[item.bundleIdentifier]
            {
                return previousHeight
            }
            
            // Manually change cell's width to prevent conflicting with UIView-Encapsulated-Layout-Width constraints.
            self.prototypeUpdateCell.frame.size.width = collectionView.bounds.width
                        
            let widthConstraint = self.prototypeUpdateCell.contentView.widthAnchor.constraint(equalToConstant: collectionView.bounds.width)
            NSLayoutConstraint.activate([widthConstraint])
            defer { NSLayoutConstraint.deactivate([widthConstraint]) }
            
            self.dataSource.cellConfigurationHandler(self.prototypeUpdateCell, item, indexPath)
            
            let size = self.prototypeUpdateCell.contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            self.cachedUpdateSizes[item.bundleIdentifier] = size
            return size

        case .activeApps, .inactiveApps:
            return CGSize(width: collectionView.bounds.width, height: 88)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize
    {
        let section = Section.allCases[section]
        switch section
        {
        case .noUpdates: return .zero
        case .updates:
            let height: CGFloat = self.updatesDataSource.itemCount > maximumCollapsedUpdatesCount ? 26 : 0
            return CGSize(width: collectionView.bounds.width, height: height)
            
        case .activeApps: return CGSize(width: collectionView.bounds.width, height: 29)
        case .inactiveApps where self.inactiveAppsDataSource.itemCount == 0: return .zero
        case .inactiveApps: return CGSize(width: collectionView.bounds.width, height: 29)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize
    {
        let section = Section.allCases[section]
        
        func appIDsFooterSize() -> CGSize
        {
            guard let _ = DatabaseManager.shared.activeTeam() else { return .zero }
            
            let indexPath = IndexPath(row: 0, section: section.rawValue)
            let footerView = self.collectionView(collectionView, viewForSupplementaryElementOfKind: UICollectionView.elementKindSectionFooter, at: indexPath) as! InstalledAppsCollectionFooterView
                        
            let size = footerView.systemLayoutSizeFitting(CGSize(width: collectionView.frame.width, height: UIView.layoutFittingExpandedSize.height),
                                                          withHorizontalFittingPriority: .required,
                                                          verticalFittingPriority: .fittingSizeLevel)
            return size
        }
        
        switch section
        {
        case .noUpdates: return .zero
        case .updates: return .zero
            
        case .activeApps where self.inactiveAppsDataSource.itemCount == 0: return appIDsFooterSize()
        case .activeApps: return .zero
            
        case .inactiveApps where self.inactiveAppsDataSource.itemCount == 0: return .zero
        case .inactiveApps: return appIDsFooterSize()
        }
    }
    
    func collectionView(_ myCV: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets
    {
        let section = Section.allCases[section]
        switch section
        {
        case .noUpdates where self.updatesDataSource.itemCount != 0: return .zero
        case .updates where self.updatesDataSource.itemCount == 0: return .zero
        default: return UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)
        }
    }
}

extension MyAppsViewController: UICollectionViewDragDelegate
{
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem]
    {
        switch Section(rawValue: indexPath.section)!
        {
        case .updates, .noUpdates:
            return []
            
        case .activeApps, .inactiveApps:
            guard UserDefaults.standard.activeAppsLimit != nil else { return [] }
            guard let cell = collectionView.cellForItem(at: indexPath as IndexPath) as? InstalledAppCollectionViewCell else { return [] }
            
            let item = self.dataSource.item(at: indexPath)
            guard item.bundleIdentifier != StoreApp.altstoreAppID else { return [] }
                        
            let dragItem = UIDragItem(itemProvider: NSItemProvider(item: nil, typeIdentifier: nil))
            dragItem.localObject = item
            dragItem.previewProvider = {
                let parameters = UIDragPreviewParameters()
                parameters.backgroundColor = .clear
                parameters.visiblePath = UIBezierPath(roundedRect: cell.bannerView.iconImageView.bounds, cornerRadius: cell.bannerView.iconImageView.layer.cornerRadius)
                
                let preview = UIDragPreview(view: cell.bannerView.iconImageView, parameters: parameters)
                return preview
            }
                            
            return [dragItem]
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters?
    {
        guard let cell = collectionView.cellForItem(at: indexPath as IndexPath) as? InstalledAppCollectionViewCell else { return nil }
        
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bannerView.frame, cornerRadius: cell.bannerView.layer.cornerRadius)
        
        return parameters
    }
    
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession)
    {
        let previousDestinationIndexPath = self.dropDestinationIndexPath
        self.dropDestinationIndexPath = nil
        
        if let indexPath = previousDestinationIndexPath
        {
            // Access cell directly to prevent UI glitches due to race conditions when refreshing
            self.updateCell(at: indexPath)
        }
    }
}

extension MyAppsViewController: UICollectionViewDropDelegate
{
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool
    {
        return session.localDragSession != nil
    }
    
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal
    {
        guard
            let activeAppsLimit = UserDefaults.standard.activeAppsLimit,
            let installedApp = session.items.first?.localObject as? InstalledApp
        else { return UICollectionViewDropProposal(operation: .cancel) }
        
        // Retrieve header attributes for location calculations.
        guard
            let activeAppsHeaderAttributes = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: Section.activeApps.rawValue)),
            let inactiveAppsHeaderAttributes = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: Section.inactiveApps.rawValue))
        else { return UICollectionViewDropProposal(operation: .cancel) }
        
        var dropDestinationIndexPath: IndexPath? = nil
        
        defer
        {
            // Animate selection changes.
            
            if dropDestinationIndexPath != self.dropDestinationIndexPath
            {
                let previousIndexPath = self.dropDestinationIndexPath
                self.dropDestinationIndexPath = dropDestinationIndexPath
                
                let indexPaths = [previousIndexPath, dropDestinationIndexPath].compactMap { $0 }
                
                let propertyAnimator = UIViewPropertyAnimator(springTimingParameters: UISpringTimingParameters()) {
                    for indexPath in indexPaths
                    {
                        // Access cell directly so we can animate it correctly.
                        self.updateCell(at: indexPath)
                    }
                }
                propertyAnimator.startAnimation()
            }
        }
        
        let point = session.location(in: collectionView)
        
        if installedApp.isActive
        {
            // Deactivating
            
            if point.y > inactiveAppsHeaderAttributes.frame.minY
            {
                // Inactive apps section.
                return UICollectionViewDropProposal(operation: .copy, intent: .insertAtDestinationIndexPath)
            }
            else if point.y > activeAppsHeaderAttributes.frame.minY
            {
                // Active apps section.
                return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
            }
            else
            {
                return UICollectionViewDropProposal(operation: .cancel)
            }
        }
        else
        {
            // Activating
            
            guard point.y > activeAppsHeaderAttributes.frame.minY else {
                // Above active apps section.
                return UICollectionViewDropProposal(operation: .cancel)
            }
            
            guard point.y < inactiveAppsHeaderAttributes.frame.minY else {
                // Inactive apps section.
                return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
            }
            
            let activeAppsCount = (self.activeAppsDataSource.fetchedResultsController.fetchedObjects ?? []).map { $0.requiredActiveSlots }.reduce(0, +)
            let availableActiveApps = max(activeAppsLimit - activeAppsCount, 0)
            
            if installedApp.requiredActiveSlots <= availableActiveApps
            {
                // Enough active app slots, so no need to deactivate app first.
                return UICollectionViewDropProposal(operation: .copy, intent: .insertAtDestinationIndexPath)
            }
            else
            {
                // Not enough active app slots, so we need to deactivate an app.
                
                // Provided destinationIndexPath is inaccurate.
                guard let indexPath = collectionView.indexPathForItem(at: point), indexPath.section == Section.activeApps.rawValue else {
                    // Invalid destination index path.
                    return UICollectionViewDropProposal(operation: .cancel)
                }
                
                let installedApp = self.dataSource.item(at: indexPath)
                guard installedApp.bundleIdentifier != StoreApp.altstoreAppID else {
                    // Can't deactivate AltStore.
                    return UICollectionViewDropProposal(operation: .forbidden, intent: .insertIntoDestinationIndexPath)
                }
                
                // This app can be deactivated!
                dropDestinationIndexPath = indexPath
                return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
            }
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator)
    {
        guard let installedApp = coordinator.session.items.first?.localObject as? InstalledApp else { return }
        guard let destinationIndexPath = coordinator.destinationIndexPath else { return }
        
        if installedApp.isActive
        {
            guard destinationIndexPath.section == Section.inactiveApps.rawValue else { return }
            self.deactivate(installedApp)
        }
        else
        {
            guard destinationIndexPath.section == Section.activeApps.rawValue else { return }
            
            switch coordinator.proposal.intent
            {
            case .insertIntoDestinationIndexPath:
                installedApp.isActive = true
                
                let previousInstalledApp = self.dataSource.item(at: destinationIndexPath)
                self.deactivate(previousInstalledApp) { (result) in
                    installedApp.managedObjectContext?.perform {
                        switch result
                        {
                        case .failure: installedApp.isActive = false
                        case .success: self.activate(installedApp)
                        }
                    }
                }
                
            case .insertAtDestinationIndexPath:
                self.activate(installedApp)
                
            case .unspecified: break
            @unknown default: break
            }
        }
    }
}

extension MyAppsViewController: NSFetchedResultsControllerDelegate
{
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        // Responding to NSFetchedResultsController updates before the collection view has
        // been shown may throw exceptions because the collection view cannot accurately
        // count the number of items before the update. However, if we manually call
        // performBatchUpdates _before_ responding to updates, the collection view can get
        // an accurate pre-update item count.
        self.collectionView.performBatchUpdates(nil, completion: nil)
        
        if controller == self.updatesDataSource.fetchedResultsController
        {
            self.updatesDataSource.controllerWillChangeContent(controller)
        }
    }
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange sectionInfo: NSFetchedResultsSectionInfo, atSectionIndex sectionIndex: Int, for type: NSFetchedResultsChangeType)
    {
        guard controller == self.updatesDataSource.fetchedResultsController else { return }
        
        self.updatesDataSource.controller(controller, didChange: sectionInfo, atSectionIndex: UInt(sectionIndex), for: type)
    }
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?)
    {
        guard controller == self.updatesDataSource.fetchedResultsController else { return }
        
        self.updatesDataSource.controller(controller, didChange: anObject, at: indexPath, for: type, newIndexPath: newIndexPath)
    }
    
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        if controller == self.hiddenUpdatesFetchedResultsController && self.updatesDataSource.itemCount == 0
        {
            // Reload noUpdates section whenever hiddenUpdatesFetchedResultsController changes (and there are no supported updates).
            // This ensures the cell correctly switches between "No Updates Available" and "Unsupported Updates Available".
            self.collectionView.reloadSections([Section.noUpdates.rawValue])
        }
        else if controller == self.updatesDataSource.fetchedResultsController
        {
            let previousUpdateCount = self.collectionView.numberOfItems(inSection: Section.updates.rawValue)
            let updateCount = Int(self.updatesDataSource.itemCount)
            
            if previousUpdateCount == 0 && updateCount > 0
            {
                // Remove "No Updates Available" cell.
                let change = RSTCellContentChange(type: .delete, currentIndexPath: IndexPath(item: 0, section: Section.noUpdates.rawValue), destinationIndexPath: nil)
                self.collectionView.add(change)
            }
            else if previousUpdateCount > 0 && updateCount == 0
            {
                // Insert "No Updates Available" cell.
                let change = RSTCellContentChange(type: .insert, currentIndexPath: nil, destinationIndexPath: IndexPath(item: 0, section: Section.noUpdates.rawValue))
                self.collectionView.add(change)
            }
            
            self.updatesDataSource.controllerDidChangeContent(controller)
        }
    }
}

extension MyAppsViewController: UIDocumentPickerDelegate
{
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
    {
        guard let fileURL = urls.first else { return }
        
        switch controller.documentPickerMode
        {
        case .import, .open:
            self.sideloadApp(at: fileURL) { (result) in
                print("Sideloaded app at \(fileURL) with result:", result)
            }
        
        case .exportToService, .moveToService: break
        @unknown default: break
        }
    }
}

extension MyAppsViewController: UIViewControllerPreviewingDelegate
{
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, viewControllerForLocation location: CGPoint) -> UIViewController?
    {
        guard
            let indexPath = self.collectionView.indexPathForItem(at: location),
            let cell = self.collectionView.cellForItem(at: indexPath)
        else { return nil }
        
        let section = Section.allCases[indexPath.section]
        switch section
        {
        case .updates:
            previewingContext.sourceRect = cell.frame
            
            let app = self.dataSource.item(at: indexPath)
            guard let storeApp = app.storeApp else { return nil}
            
            let appViewController = AppViewController.makeAppViewController(app: storeApp)
            return appViewController
            
        default: return nil
        }
    }
    
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, commit viewControllerToCommit: UIViewController)
    {
        let point = CGPoint(x: previewingContext.sourceRect.midX, y: previewingContext.sourceRect.midY)
        guard let indexPath = self.collectionView.indexPathForItem(at: point), let cell = self.collectionView.cellForItem(at: indexPath) else { return }
        
        self.performSegue(withIdentifier: "showUpdate", sender: cell)
    }
}

extension MyAppsViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate
{
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any])
    {
        defer {
            picker.dismiss(animated: true, completion: nil)
            self._imagePickerInstalledApp = nil
        }
        
        guard let image = info[.editedImage] as? UIImage, let installedApp = self._imagePickerInstalledApp else { return }
        self.changeIcon(for: installedApp, to: image)
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController)
    {
        picker.dismiss(animated: true, completion: nil)
        self._imagePickerInstalledApp = nil
    }
}
