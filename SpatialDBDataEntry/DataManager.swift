//
//  DataManager.swift
//  SpatialDBDataEntry
//
//  Created by Karan Sequeira on 11/29/17.
//  Copyright © 2017 University of Utah. All rights reserved.
//

import CoreLocation
import Foundation

protocol DataManagerResponseDelegate: class {
    func receiveSites(errorMessage: String, sites: [Site])
}

class DataManager: NSObject
{
    static let shared: DataManager = DataManager()
    
    //MARK: Data
    var enableSampleProjects: Bool = false
    var projects: [Project] = [Project]()
    var cachedSites: [Site] = [Site]()
    private var isSavingCachedSites: Bool = false
    private var isLoadingCachedSites: Bool = false
    
    //MARK: Tasks
    var session: URLSession?
    var fetchSitesDataTask: URLSessionDataTask?
    var fetchAllSitesDataTask: URLSessionDataTask?
    
    //MARK: Archiving paths
    
    private static let documentsDirectory = FileManager().urls(for: .documentDirectory, in: .userDomainMask).first!
    private static let projectsArchiveURL = documentsDirectory.appendingPathComponent("projects")
    private static let cachedSitesArchiveURL = documentsDirectory.appendingPathComponent("cachedSites")
    
    //MARK: Initialization
    
    private override init() {
        super.init()
        
        session = URLSession(configuration: .default)
    }
    
    //MARK: Site fetching based on network connection
    
    func fetchSites(delegate: DataManagerResponseDelegate, minLatLong: CLLocationCoordinate2D, maxLatLong: CLLocationCoordinate2D) {
        if Reachability.isConnectedToNetwork() {
            fetchSitesRemote(delegate: delegate, minLatLong: minLatLong, maxLatLong: maxLatLong)
        }
        else {
            fetchSitesFromCache(delegate: delegate, minLatLong: minLatLong, maxLatLong: maxLatLong)
        }
    }
    
    //MARK: Remote site fetching
    
    private func fetchSitesRemote(delegate: DataManagerResponseDelegate, minLatLong: CLLocationCoordinate2D, maxLatLong: CLLocationCoordinate2D) {
        print("Fetching sites from database")
        
        fetchSitesDataTask?.cancel()

        let sitesURL: URL = URL(string: "http://wateriso.utah.edu/api/sites_for_mobile.php")!
        var sitesRequest: URLRequest = URLRequest(url: sitesURL)
        
        sitesRequest.httpMethod = "POST"
        sitesRequest.addValue("application/json", forHTTPHeaderField: "ContentType")
        
        let sitesRequestBodyString: String = "{" +
            "\"latitude\": { \"Min\": \(minLatLong.latitude), \"Max\": \(maxLatLong.latitude) }," +
            "\"longitude\": { \"Min\": \(minLatLong.longitude), \"Max\": \(maxLatLong.longitude) }" +
        "}"
        
        let sitesRequestBodyData: Data = sitesRequestBodyString.data(using: .utf8)!
        sitesRequest.httpBody = sitesRequestBodyData
        
        fetchSitesDataTask = session!.dataTask(with: sitesRequest) { data, response, error in
            defer { self.fetchSitesDataTask = nil }
            
            var errorMessage: String = "";
            if let error = error {
                errorMessage += error.localizedDescription
            }
            else if let data = data {
                DispatchQueue.global(qos: .userInteractive).async {
                    self.receiveRemoteSites(data, delegate: delegate, errorMessage: errorMessage)
                }
            }
        }
        
        fetchSitesDataTask?.resume()
    }
    
    func fetchAllSites(delegate: DataManagerResponseDelegate) {
        print("Fetching all sites from database.")
        
        fetchAllSitesDataTask?.cancel()
        
        let sitesURL: URL = URL(string: "http://wateriso.utah.edu/api/sites.php")!
        var sitesRequest: URLRequest = URLRequest(url: sitesURL)
        
        sitesRequest.httpMethod = "POST"
        sitesRequest.addValue("application/json", forHTTPHeaderField: "ContentType")
        
        let sitesRequestBodyString: String = "{\"latitude\":null,\"longitude\":null,\"elevation\":null,\"countries\":null,\"states\":null,\"collection_date\":null,\"types\":null,\"h2\":null,\"o18\":null,\"project_ids\":null}"
        
        let sitesRequestBodyData: Data = sitesRequestBodyString.data(using: .utf8)!
        sitesRequest.httpBody = sitesRequestBodyData
        
        fetchAllSitesDataTask = session!.dataTask(with: sitesRequest) { data, response, error in
            defer { self.fetchAllSitesDataTask = nil }
            
            var errorMessage: String = "";
            if let error = error {
                errorMessage += error.localizedDescription
            }
            else if let data = data {
                DispatchQueue.global(qos: .utility).async {
                    self.receiveRemoteSites(data, delegate: delegate, errorMessage: errorMessage)
                }
            }
        }
        
        fetchAllSitesDataTask?.resume()
    }
    
    //MARK: Cached sites fetching
    
    private func fetchSitesFromCache(delegate: DataManagerResponseDelegate, minLatLong: CLLocationCoordinate2D, maxLatLong: CLLocationCoordinate2D) {
        DispatchQueue.global(qos: .userInteractive).async {
            var sites: [Site] = []
            for site in self.cachedSites {
                // North - Positive
                // East - Positive
                if site.location.latitude < minLatLong.latitude ||
                    site.location.longitude < minLatLong.longitude ||
                    site.location.latitude > maxLatLong.latitude ||
                    site.location.longitude > maxLatLong.longitude {
                    continue
                }
                
                sites.append(site)
            }

            DispatchQueue.main.async {
                delegate.receiveSites(errorMessage: "", sites: sites)
            }
        }
    }
    
    //MARK: Site receiving and parsing
    
    private func receiveRemoteSites(_ data: Data, delegate: DataManagerResponseDelegate, errorMessage: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            print("Couldn't get JSON from response!")
            return
        }
        
        guard let dict = json as? [String: Any] else {
            print("Couldn't parse response!")
            return
        }
        
        guard let sitesDict = dict["sites"] as? [Any] else {
            print("Couldn't get sites from response!")
            return
        }
        
        var sites: [Site] = []
        for siteFromDict in sitesDict {
            guard let siteDict = siteFromDict as? [String: Any] else {
                print("Couldn't get site from response")
                return
            }
            
            let id = siteDict["Site_ID"] as? String
            let name = siteDict["Site_Name"] as? String
            let latitude = siteDict["Latitude"] as? Double
            let longitude = siteDict["Longitude"] as? Double
            let coordinate = CLLocationCoordinate2D(latitude: latitude!, longitude: longitude!)
            
            let site: Site = Site(id: id ?? "nil", name: name ?? "", location: coordinate)!
            
            sites.append(site)
        }

        DispatchQueue.main.async {
            delegate.receiveSites(errorMessage: errorMessage, sites: sites)
        }
    }
    
    //MARK: Data exporting
    
    func exportSelectedProjects(selectedProjects: [Project]) -> (projectsString: String, sitesString: String, samplesString: String) {
        // Create containers
        var projectsString = "Project_ID,Contact_Name,Contact_Email,Citation,URL,Project_Name,Proprietary\n"
        var sitesString = "Site_ID,Site_Name,Latitude,Longitude,Elevation_mabsl,Address,City,State_or_Province,Country,Site_Comments\n"
        var samplesString = "Sample_ID,Sample_ID_2,Site_ID,Type,Start_Date,Start_Time,Collection_Date,Collection_Time,Sample_Volume_ml,Collector_type,Phase,Depth_meters,Sample_Source,Sample_Ignore,Sample_Comments,Project_ID\n"
        
        // Export each project
        for project in selectedProjects {
            projectsString.append(exportSingle(project: project))
            
            // Export each site
            for site in project.sites {
                sitesString.append(exportSingle(site: site, project: project))
            }
            
            // Export each sample
            for sample in project.samples {
                samplesString.append(exportSingle(sample: sample, project: project))
            }
        }
        
        return (projectsString, sitesString, samplesString)
    }
    
    private func exportSingle(project: Project) -> String {
        return "\(project.name),\(project.contactName),\(project.contactEmail),,,\(project.name)\n"
    }
    
    private func exportSingle(site: Site, project: Project) -> String {
        let elevationString: String = site.elevation < 0 ? "" : String(site.elevation)
        
        return "\(site.id),\(site.name),\(Double(site.location.latitude)),\(Double(site.location.longitude)),\(elevationString),\(site.address),\(site.city),\(site.stateOrProvince),\(site.country),\(site.comments)\n"
    }
    
    private func exportSingle(sample: Sample, project: Project) -> String {
        var startDateString: String = ""
        var startTimeString: String = ""
        if sample.startDateTime.compare(Date.distantFuture) == ComparisonResult.orderedAscending {
            startDateString = DateFormatter.localizedString(from: sample.startDateTime, dateStyle: .short, timeStyle: .none)
            startTimeString = DateFormatter.localizedString(from: sample.startDateTime, dateStyle: .none, timeStyle: .short)
        }
        
        let collectionDateString: String = DateFormatter.localizedString(from: sample.dateTime, dateStyle: .short, timeStyle: .none)
        let collectionTimeString: String = DateFormatter.localizedString(from: sample.dateTime, dateStyle: .none, timeStyle: .short)
        let depthString: String = sample.depth < 0 ? "" : String(sample.depth)
        let volumeString: String = sample.volume < 0 ? "" : String(sample.volume)
        
        return "\(sample.id),,\(sample.siteID),\(sample.type.description),\(startDateString),\(startTimeString),\(collectionDateString),\(collectionTimeString),\(volumeString),,\(sample.phase.description),\(depthString),,,\(sample.comments),\(project.name)\n"
    }
    
    //MARK: Data saving and loading
    
    func saveProjects() {
        let isSuccessfulSave = NSKeyedArchiver.archiveRootObject(projects, toFile: DataManager.projectsArchiveURL.path)
        
        if isSuccessfulSave {
            print("Projects saved successfully.")
        }
        else {
            print("Projects failed to save!")
        }
    }
    
    func loadProjects() {
        if enableSampleProjects {
            deleteSavedProjects()
            loadSampleProjects()
            return
        }
        
        if let savedProjects = NSKeyedUnarchiver.unarchiveObject(withFile: DataManager.projectsArchiveURL.path) as? [Project] {
            projects = savedProjects
            print("Projects loaded successfully.")
        }
        else {
            print("Projects failed to load!")
        }
    }
    
    func saveCachedSites() {
        if isSavingCachedSites {
            print("An ongoing save cached sites operation hasn't finished!")
            return
        }
        
        if cachedSites.isEmpty {
            print("Attempt was made to save empty cached sites list!")
            return
        }
        
        print("Saving cached sites.")
        isSavingCachedSites = true
        
        if NSKeyedArchiver.archiveRootObject(cachedSites, toFile: DataManager.cachedSitesArchiveURL.path) {
            print("Cached sites saved successfully.")
        }
        else {
            print("Cached sites failed to save!")
        }
        
        isSavingCachedSites = false
    }
    
    func loadCachedSites() {
        if isLoadingCachedSites {
            print("An ongoing load cached sites operation hasn't finished!")
            return
        }
        
        print("Loading cached sites.")
        isLoadingCachedSites = true
        
        if let savedCachedSites = NSKeyedUnarchiver.unarchiveObject(withFile: DataManager.cachedSitesArchiveURL.path) as? [Site] {
            cachedSites = savedCachedSites
            print("Cached sites loaded successfully.")
        }
        else {
            print("Cached sites failed to load!")
        }
        
        isLoadingCachedSites = false
    }
    
    private func loadSampleProjects() {
        let location = CLLocationCoordinate2DMake(CLLocationDegrees(40.759341), CLLocationDegrees(-111.861879))
        
        guard let site1 = Site(id: "TP1-JD-SITE-01", name: "Site_01", location: location) else {
            fatalError("Unable to instantiate site1")
        }
        
        let date = Date()
        guard let sample1 = Sample(id: "TP1-JD-SAMPLE-01", siteID: "TP1-JD-SITE-01", type: SampleType.lake, dateTime: date, startDateTime: date, siteLocation: location) else {
            fatalError("Unable to instantiate sample1")
        }
        
        guard let project1 = Project(name: "TestProject_01", contactName: "John Doe", contactEmail: "", sampleIDPrefix: "TP1-JD-", sites: [site1], samples: [sample1]) else {
            fatalError("Unable to instantiate project1")
        }
        
        projects += [project1]
        
        print("Sample projects loaded successfully.")
    }
    
    private func deleteSavedProjects() {
        let fileManager = FileManager.default
        
        do {
            try fileManager.removeItem(atPath: DataManager.projectsArchiveURL.path)
            print("Saved projects deleted successfully.")
        }
        catch {
            print("Failed to delete failed projects!")
        }
    }

}
