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
    func receiveSite(errorMessage: String, site: Site)
}

class DataManager: NSObject
{
    static let shared: DataManager = DataManager()
    
    //MARK: Data
    var projects: [Project] = [Project]()
    var cachedSites: [Site] = [Site]()
    private var isSavingCachedSites: Bool = false
    private var isLoadingCachedSites: Bool = false
    
    //MARK: Tasks
    var session: URLSession?
    var fetchSitesDataTask: URLSessionDataTask?
    var fetchSiteDataTask: URLSessionDataTask?
    
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

        let sitesURL: URL = URL(string: "https://wateriso.utah.edu/api/sites_for_mobile.php")!
//        let sitesURL: URL = URL(string: "http://wateriso.utah.edu/api/sites.php")!
        var sitesRequest: URLRequest = URLRequest(url: sitesURL)
        
        sitesRequest.httpMethod = "POST"
        sitesRequest.addValue("application/json", forHTTPHeaderField: "ContentType")
/*
        let sitesRequestBodyString: String = "{" +
            "\"latitude\": { \"Min\": \(minLatLong.latitude), \"Max\": \(maxLatLong.latitude) }," +
            "\"longitude\": { \"Min\": \(minLatLong.longitude), \"Max\": \(maxLatLong.longitude) }" +
            ",\"elevation\":null,\"countries\":null,\"states\":null,\"collection_date\":null,\"types\":null,\"h2\":null,\"o18\":null,\"project_ids\":null}" */

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
    
    //MARK: Fetch details for a single site using ID
    
    func fetchSite(delegate: DataManagerResponseDelegate, site: Site, projectIndex: Int) {
        if Reachability.isConnectedToNetwork() {

            print("Fetching site from database")
            
            fetchSiteDataTask?.cancel()
            
            let sitesURL: URL = URL(string: "https://wateriso.utah.edu/api/siteinfo.php")!
            var sitesRequest: URLRequest = URLRequest(url: sitesURL)

            sitesRequest.httpMethod = "POST"
            sitesRequest.addValue("application/json", forHTTPHeaderField: "ContentType")
            
            let sitesRequestBodyString: String = "{\"site_id\":\"\(site.id)\"}"
            
            let sitesRequestBodyData: Data = sitesRequestBodyString.data(using: .utf8)!
            sitesRequest.httpBody = sitesRequestBodyData
            
            fetchSiteDataTask = session!.dataTask(with: sitesRequest) { data, response, error in
                defer { self.fetchSiteDataTask = nil }
                
                var errorMessage: String = "";
                if let error = error {
                    errorMessage += error.localizedDescription
                }
                else if let data = data {
                    DispatchQueue.global(qos: .userInteractive).async {
                        if !self.receiveRemoteSite(data, delegate: delegate, errorMessage: errorMessage, projectIndex: projectIndex) {
                            print("Appending cached site")
                            self.appendSite(site, projectIndex: projectIndex)
                        }
                    }
                }
            }
            
            fetchSiteDataTask?.resume()
        }
        
        else{
            print("Appending cached site")
            appendSite(site, projectIndex: projectIndex)
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
        
        let nsites = sitesDict.count
        print("Received " + String(nsites) + " sites")

        DispatchQueue.main.async {
            delegate.receiveSites(errorMessage: errorMessage, sites: sites)
        }
    }
    
    //MARK: Site receiving and parsing
    
    private func receiveRemoteSite(_ data: Data, delegate: DataManagerResponseDelegate, errorMessage: String, projectIndex: Int) -> Bool {
        
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            print("Couldn't get JSON from response!")
            return false
        }
        
        guard let dict = json as? [String: Any] else {
            print("Couldn't parse response!")
            return false
        }
        
        let stat = dict["status"] as? [String: Any]
        print(stat!["Code"] ?? "No Code")
        
        guard let siteDict = dict["site"] as? [String: Any] else {
            print("Couldn't get sites from response!")
            return false
        }
        
        let id = siteDict["Site_ID"] as? String
        let name = siteDict["Site_Name"] as? String
        let latitude = siteDict["Latitude"] as? Double
        let longitude = siteDict["Longitude"] as? Double
        let coordinate = CLLocationCoordinate2D(latitude: latitude!, longitude: longitude!)
            
        let site = Site(id: id ?? "nil", name: name ?? "", location: coordinate)!
            
        let elevation = siteDict["Elevation_mabsl"] as? Double
        let address = siteDict["Address"] as? String
        let city = siteDict["City"] as? String
        let stateOrProvince = siteDict["State_or_Province"] as? String
        let country = siteDict["Country"] as? String
        let comments = siteDict["Site_Comments"] as? String
            
        site.elevation = elevation ?? -9999
        site.address = address ?? ""
        site.city = city ?? ""
        site.stateOrProvince = stateOrProvince ?? ""
        site.country = country ?? ""
        site.comments = comments ?? ""
        
        appendSite(site, projectIndex: projectIndex)
        return true

    }
    
    private func appendSite(_ site: Site, projectIndex: Int) {
        DataManager.shared.projects[projectIndex].sites.append(site)
    }
    
    //MARK: Data exporting
    
    func exportSelectedProjects(selectedProjects: [Project]) -> (projectsString: String, sitesString: String, samplesString: String) {
        // Create containers
        var projectsString = "Project_ID,Contact_Name,Contact_Email,Citation,URL,Project_Name,Proprietary\n"
        var sitesString = "Site_ID,Site_Name,Latitude,Longitude,Elevation_mabsl,Address,City,State_or_Province,Country,Site_Comments\n"
        var samplesString = "Sample_ID,Sample_ID_2,Site_ID,Type,Start_Date,Start_Time_Zone,Collection_Date,Collection_Time_Zone,Sample_Volume_ml,Collector_type,Phase,Depth_meters,Sample_Source,Sample_Ignore,Sample_Comments,Project_ID\n"
        
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
        let projectString: String = "\"" + project.name + "\""
        return "\(project.name),\(project.contactName),\(project.contactEmail),,,\(projectString)\n"
    }
    
    private func exportSingle(site: Site, project: Project) -> String {
        var elevationString: String = site.elevation == -9999 ? "" : String(site.elevation)
        if (elevationString == "-1.0") {
            elevationString = "-9999"
        }
        
        let siteIDString: String = "\"" + site.id + "\""
        let sitenameString: String = "\"" + site.name + "\""
        let addressString: String = "\"" + site.address + "\""
        let cityString: String = "\"" + site.city + "\""
        let commentString: String = "\"" + site.comments + "\""
        
        return "\(siteIDString),\(sitenameString),\(Double(site.location.latitude)),\(Double(site.location.longitude)),\(elevationString),\(addressString),\(cityString),\(site.stateOrProvince),\(site.country),\(commentString)\n"
    }
    
    private func exportSingle(sample: Sample, project: Project) -> String {
        var startDateTimeString: String = ""
        if sample.startDateTime.compare(Date.distantFuture) == ComparisonResult.orderedAscending {
            startDateTimeString = getDateTimeString(dateTime: sample.startDateTime)
        }
        
        let sampleIDString: String = "\"" + sample.id + "\""
        let siteIDString: String = "\"" + sample.siteID + "\""
        let collectionDateTimeString: String = getDateTimeString(dateTime: sample.dateTime)
        let depthString: String = sample.depth == -9999 ? "" : String(sample.depth)
        let volumeString: String = sample.volume == -9999 ? "" : String(sample.volume)
        let commentString: String = "\"" + sample.comments + "\""
        let projectString: String = "\"" + project.name + "\""
        
        return "\(sampleIDString),,\(siteIDString),\(sample.type.description),\(startDateTimeString),\(sample.startDateTimeZone.secondsFromGMT() / 3600),\(collectionDateTimeString),\(sample.dateTimeZone.secondsFromGMT() / 3600),\(volumeString),,\(sample.phase.description),\(depthString),,,\(commentString),\(projectString)\n"
    }
    
    private func getDateTimeString(dateTime: Date) -> String {
        let dateString: String = DateFormatter.localizedString(from: dateTime, dateStyle: .short, timeStyle: .none)
        let timeString: String = DateFormatter.localizedString(from: dateTime, dateStyle: .none, timeStyle: .short)
        return String(dateString + " " + timeString)
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

}
