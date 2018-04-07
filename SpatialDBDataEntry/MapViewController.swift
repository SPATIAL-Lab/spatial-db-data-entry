//
//  MapViewController.swift
//  SpatialDBDataEntry
//
//  Created by Karan Sequeira on 10/27/17.
//  Copyright © 2017 University of Utah. All rights reserved.
//

import UIKit
import MapKit
import CoreLocation

enum MapPanFetchResultType: Int {
    case withinWindow
    case leftOfWindow
    case rightOfWindow
    case aboveWindow
    case belowWindow
    
    var description: String {
        switch self {
        case .withinWindow:         return "Within Window"
        case .leftOfWindow:         return "Left of Window"
        case .rightOfWindow:        return "Right of Window"
        case .aboveWindow:          return "Above Window"
        case .belowWindow:          return "Below Window"
        }
    }
    
    static var count: Int {
        return 5
    }
}

class MapViewController: UIViewController,
    CLLocationManagerDelegate,
    MKMapViewDelegate,
    DataManagerResponseDelegate {
    
    //MARK: Properties
    
    //TODO: Find a better place for this such that
    // location should start updating before the map view is loaded.
    let locationManager = CLLocationManager()
    
    @IBOutlet weak var saveButton: UIBarButtonItem!
    @IBOutlet weak var mapView: MKMapView!
    
    // Project properties
    var projectIndex: Int = -1
    
    // MapView properties
    var lastUpdatedLocation: CLLocation = CLLocation()
    let maxMapZoomLongitude: Double = 0.05
    var siteAnnotationList: [SiteAnnotation] = []
    var lastRegionCenter: CLLocationCoordinate2D = CLLocationCoordinate2D()
    var selectedSiteInitialized: Bool = false
    var hasUserPannedTheMap: Bool = false
    var newlyAddedAnnotation: SiteAnnotation = SiteAnnotation()
    
    // Site fetching
    var hasFetchedInitially: Bool = false
    let siteFetchWindowSize: Double = 10
    var deltaLatLong: Double = 0
    let siteFetchIncrementSize: Double = 0.045 // (5km / earthRadius) * radiansToDegrees
    let minLocationErrorTolerance: Double = 5
    var lastMinLatLong: CLLocationCoordinate2D = CLLocationCoordinate2D()
    var lastMaxLatLong: CLLocationCoordinate2D = CLLocationCoordinate2D()

    // Site properties
    var selectedExistingSite: Bool = false
    var existingSiteID: String = ""
    var existingSiteLocation: CLLocationCoordinate2D = CLLocationCoordinate2D()
    var newSiteID: String = ""
    
    override func viewDidLoad() {
        super.viewDidLoad()

        mapView.delegate = self
        
        let gestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(sender:)))
        self.view!.addGestureRecognizer(gestureRecognizer)
        
        // Write some usable values beforehand
        deltaLatLong = getDeltaLatLong(rangeInKM: siteFetchWindowSize)
        newSiteID = DataManager.shared.projects[projectIndex].getIDForNewSite()
        
        // Plot saved sites
        plotSavedSites()
        
        // Check if an existing site has been selected
        if !existingSiteID.isEmpty {
            hasFetchedInitially = true
            
            // Get a window around the selected site's location
            let (minLatLong, maxLatLong) = getMinMaxLatLong(location: existingSiteLocation)
            
            // Update the window dimensions
            updateWindow(mapRegionCenter: existingSiteLocation, minLatLong: minLatLong, maxLatLong: maxLatLong)
            
            // Fetch sites for the current window
            fetchSites(minLatLong: minLatLong, maxLatLong: maxLatLong)
        }
        
        // Initialize location
        // Request location usage
        locationManager.requestWhenInUseAuthorization()
        
        // Setup location services
        if CLLocationManager.locationServicesEnabled() {
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.startUpdatingLocation()
        }
        else {
            print("Location services are disabled!")
        }
        
        // Enable the save button if viewing an existing site
        saveButton.isEnabled = selectedExistingSite
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
        // TODO: Dispose the oldest sites from the annotations list
    }
    
    //MARK: CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Save off the difference from the previous update
        let distanceFromLastUpdatedLocation = manager.location!.distance(from: lastUpdatedLocation)
        lastUpdatedLocation = manager.location!
        
        // Fetch initial sites only once
        // Fetch initial sites only if the updated location has stabilized
        if !hasFetchedInitially && distanceFromLastUpdatedLocation.isLess(than: minLocationErrorTolerance) {
            hasFetchedInitially = true
            
            // Get a window around the user's current location
            let (minLatLong, maxLatLong) = getMinMaxLatLong(location: lastUpdatedLocation.coordinate)
            
            // Update the window dimensions
            updateWindow(mapRegionCenter: lastUpdatedLocation.coordinate, minLatLong: minLatLong, maxLatLong: maxLatLong)
            
            // Fetch sites for the current window
            fetchSites(minLatLong: minLatLong, maxLatLong: maxLatLong)
        }
    }
    
    //MARK: MKMapViewDelegate
    
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let annotation = annotation as? SiteAnnotation else {
            return nil
        }
        
        let identifier = "SiteAnnotation"
        var view: MKPinAnnotationView
        
        // Reuse a dequeued view else create one
        if let dequeuedView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKPinAnnotationView {
            dequeuedView.annotation = annotation
            view = dequeuedView
        }
        else {
            view = MKPinAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.canShowCallout = true
        }
        
        // Check if the site annotation matches with the selected location
        if annotation.id.isEmpty == false &&
            annotation.id == existingSiteID {
            view.pinTintColor = UIColor.yellow
        }
        else {
            view.pinTintColor = UIColor.orange
        }
        
        return view
    }
    
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if let pinAnnotation = view as? MKPinAnnotationView {
            pinAnnotation.pinTintColor = UIColor.yellow
        }
        
        // Center the map on the selected annotation
        mapView.setCenter((view.annotation?.coordinate)!, animated: true)
        
        // Check what kind of annotation was clicked
        if let siteAnnotation = view.annotation as? SiteAnnotation {
            // Remove the newly added annotation if it wasn't selected
            if siteAnnotation != newlyAddedAnnotation {
                removeNewlyAddedSite()
            }
            
            existingSiteID = siteAnnotation.id
            existingSiteLocation = siteAnnotation.coordinate
            navigationItem.title = siteAnnotation.id
        }
        else {
            existingSiteID = ""
            existingSiteLocation = CLLocationCoordinate2D()
            navigationItem.title = "My Location"
        }
        
        saveButton.isEnabled = true
    }
    
    func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
        if let pinAnnotation = view as? MKPinAnnotationView {
            pinAnnotation.pinTintColor = UIColor.orange
        }
        
        // Remove the newly added annotation if it was deselected
        if let siteAnnotation = view.annotation as? SiteAnnotation {
            if siteAnnotation == newlyAddedAnnotation {
                removeNewlyAddedSite()
            }
        }
        
        existingSiteID = ""
        existingSiteLocation = CLLocationCoordinate2D()
        navigationItem.title = ""
        saveButton.isEnabled = false
    }
    
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        
        hasUserPannedTheMap = true
        
        // Check if the map has been zoomed out beyond the maximum
        if Double(mapView.region.span.longitudeDelta) > maxMapZoomLongitude {
            let correctedCenter = existingSiteID.isEmpty ? lastUpdatedLocation.coordinate : existingSiteLocation
            
            // Zoom back in to the user's current location
            let correctedRegion = MKCoordinateRegionMake(correctedCenter, MKCoordinateSpanMake(maxMapZoomLongitude * 0.9, maxMapZoomLongitude * 0.9))
            mapView.setRegion(correctedRegion, animated: true)
            
            hasUserPannedTheMap = false
            
            return
        }
        
        // Check if the map has been panned far enough to fetch new sites
        let mapPanFetchResult = mustFetchSites(newMapRegionCenter: mapView.region.center)
        
        if mapPanFetchResult != MapPanFetchResultType.withinWindow {
            print("MapPanFetchResult: \(mapPanFetchResult.description)")
            
            // Get a window around the map's current center
            let (minLatLong, maxLatLong) = getMinMaxLatLong(location: mapView.region.center)
            
            // Update the window
            updateWindow(mapRegionCenter: mapView.region.center, minLatLong: minLatLong, maxLatLong: maxLatLong)

            // Fetch sites around the map's current center
            fetchSites(minLatLong: minLatLong, maxLatLong: maxLatLong)
        }
    }
    
    //MARK: DataManagerResponseDelegate
    
    func receiveSites(errorMessage: String, sites: [Site]) {
        DispatchQueue.global(qos: .userInteractive).async {
            // Get site annotations for each received site
            let receivedSites = SiteAnnotation.loadSiteAnnotations(fromSites: sites)
            
            // Filter out annotations that are already cached
            let newSites = self.getNewSitesFromReceivedSites(receivedSiteAnnotations: receivedSites)
            
            DispatchQueue.main.async {
                self.plotReceivedSites(newSites: newSites, receivedSites: receivedSites)
            }
        }
    }
    
    // MARK: Navigation
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)
        
        if segue.identifier == "ShowSiteView" {
            guard let navigationController = segue.destination as? UINavigationController else {
                fatalError("Unexpected destination \(segue.destination)")
            }
            
            guard let siteViewController = navigationController.viewControllers[0] as? SiteViewController else {
                fatalError("Unexpected presented view controller \(navigationController.presentedViewController)")
            }
            
            siteViewController.generatedSiteID = newSiteID
            siteViewController.projectIndex = projectIndex
            
            // Check if an annotation was added by the user
            if newlyAddedAnnotation.title == nil {
                // If no annotation was added, use the last updated location
                siteViewController.newLocation = lastUpdatedLocation
            }
            else {
                // Use the annotation that the user added
                siteViewController.newLocation = CLLocation(latitude: newlyAddedAnnotation.coordinate.latitude, longitude: newlyAddedAnnotation.coordinate.longitude)
            }
        }
    }
    
    //MARK: Actions
    
    @IBAction func cancelSetLocation(_ sender: UIBarButtonItem) {
        dismiss(animated: true, completion: nil)
    }
    
    @IBAction func saveLocation(_ sender: UIBarButtonItem) {
        // Check if an existing site id exists
        selectedExistingSite = !existingSiteID.isEmpty
        
        if selectedExistingSite {
            // If an existing site was selected, unwind to the sample view
            performSegue(withIdentifier: "UnwindOnSiteSelected", sender: self)
            }
        else {
            // If a new site was selected, show the site view
            performSegue(withIdentifier: "ShowSiteView", sender: self)
        }
    }
    
    //MARK: Site Plotting Methods
    
    @objc private func handleLongPress(sender: UILongPressGestureRecognizer) {
        // Add an offset acounting for the finger
        let fingerOffsetX: CGFloat = -10
        let fingerOffsetY: CGFloat = -125
        var pressLocation = sender.location(in: self.view!)
        pressLocation.x += fingerOffsetX
        pressLocation.y += fingerOffsetY
        
        // Get a map coordinate form the press location
        let coordinateInMap = mapView!.convert(pressLocation, toCoordinateFrom: mapView)
        
        // Check whether a new annotation needs to be added
        // or an existing one needs to be updated
        if (newlyAddedAnnotation.title == nil) {
            newlyAddedAnnotation.coordinate = coordinateInMap
            newlyAddedAnnotation.title = "New Site"
            
            siteAnnotationList.append(newlyAddedAnnotation)
            mapView.addAnnotation(newlyAddedAnnotation)
        }
        else {
            // Simply adjusting the coordinate doesn't update the map at all
            // Thus, we remove the annotation and add it again
            mapView.removeAnnotation(newlyAddedAnnotation)
            newlyAddedAnnotation.coordinate = coordinateInMap
            mapView.addAnnotation(newlyAddedAnnotation)
        }
    }
    
    private func plotSavedSites() {
        for savedProject in DataManager.shared.projects {
            let savedSiteAnnotations = SiteAnnotation.loadSiteAnnotations(fromSites: savedProject.sites)
            siteAnnotationList.append(contentsOf: savedSiteAnnotations)
            mapView.addAnnotations(siteAnnotationList)
        }
    }
    
    private func plotReceivedSites(newSites: [SiteAnnotation], receivedSites: [SiteAnnotation]) {
        if !newSites.isEmpty {
            print("Plotting \(newSites.count) out of \(receivedSites.count) received sites")
            
            // Save the new sites
            siteAnnotationList.append(contentsOf: newSites)
            
            // Plot the site annotations
            mapView.addAnnotations(newSites)
            
            // Center map on selected location if valid else ask location manager
            initSelectedSite()
            
            print("SiteAnnotations:\(siteAnnotationList.count) MapAnnotations:\(mapView.annotations.count)")
        }
    }
    
    private func initSelectedSite() {
        if selectedSiteInitialized ||
            hasUserPannedTheMap {
            return
        }
        
        // If a site was selected, center the map around its location
        if !existingSiteID.isEmpty {
            // Select the annotation that matches the selected location's site ID
            for siteAnnotation in siteAnnotationList {
                if siteAnnotation.id == existingSiteID {
                    mapView.setCenter(siteAnnotation.coordinate, animated: true)
                    mapView.selectAnnotation(siteAnnotation, animated: true)
                    navigationItem.title = siteAnnotation.id
                    
                    selectedSiteInitialized = true
                    return
                }
            }
        }
        // If we're online, center the map around the user's location
        else if Reachability.isConnectedToNetwork() {
            mapView.setCenter(locationManager.location!.coordinate, animated: true)
        }
    }
    
    private func removeNewlyAddedSite() {
        // Check if the annotation was added to the map
        if newlyAddedAnnotation.title == nil {
            return;
        }
        
        // Remove the annotation from the map view and
        mapView.removeAnnotation(newlyAddedAnnotation)
        if let index = siteAnnotationList.index(of: newlyAddedAnnotation) {
            siteAnnotationList.remove(at: index)
        }
        
        // Reset the annotation
        newlyAddedAnnotation.coordinate = CLLocationCoordinate2D()
        newlyAddedAnnotation.title = nil
    }
    
    //MARK: Site Fetch Methods
    
    private func fetchSites(minLatLong: CLLocationCoordinate2D, maxLatLong: CLLocationCoordinate2D) {
        // Request for sites in the range of latitude and longitude
        DataManager.shared.fetchSites(delegate: self, minLatLong: minLatLong, maxLatLong: maxLatLong)
    }
    
    private func getNewSitesFromReceivedSites(receivedSiteAnnotations: [SiteAnnotation]) -> [SiteAnnotation] {
        // Filter out existing sites
        let newSiteAnnotations = receivedSiteAnnotations.filter {
            !siteAnnotationList.contains($0)
        }

        return newSiteAnnotations
    }
    
    private func mustFetchSites(newMapRegionCenter: CLLocationCoordinate2D) -> MapPanFetchResultType {
        if newMapRegionCenter.latitude < lastMinLatLong.latitude {
            return MapPanFetchResultType.belowWindow
        }
        else if newMapRegionCenter.longitude < lastMinLatLong.longitude {
            return MapPanFetchResultType.leftOfWindow
        }
        else if newMapRegionCenter.latitude > lastMaxLatLong.latitude {
            return MapPanFetchResultType.aboveWindow
        }
        else if newMapRegionCenter.longitude > lastMaxLatLong.longitude {
            return MapPanFetchResultType.rightOfWindow
        }
        
        return MapPanFetchResultType.withinWindow
    }
    
    //MARK: Map Manipulation Methods
    
    private func updateWindow(mapRegionCenter: CLLocationCoordinate2D, minLatLong: CLLocationCoordinate2D, maxLatLong: CLLocationCoordinate2D) {
        lastRegionCenter = mapRegionCenter
        lastMinLatLong = minLatLong
        lastMaxLatLong = maxLatLong
    }
    
    private func getMinMaxLatLong(location: CLLocationCoordinate2D) -> (min: CLLocationCoordinate2D, max: CLLocationCoordinate2D) {
        let latitude: Double = Double(location.latitude)
        let longitude: Double = Double(location.longitude)
        
        let degreesToRadians: Double = Double.pi / 180
        
        let minLatitude = latitude - deltaLatLong
        let maxLatitude = latitude + deltaLatLong
        let minLongitude = longitude - deltaLatLong / cos(latitude * degreesToRadians)
        let maxLongitude = longitude + deltaLatLong / cos(latitude * degreesToRadians)
        
        return (CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude), CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude))
    }
    
    private func getDeltaLatLong(rangeInKM: Double) -> Double {
        let radiusEarth: Double = 6378
        let radiansToDegrees: Double = 180 / Double.pi
        let deltaLatLong = (rangeInKM / radiusEarth) * radiansToDegrees
        return deltaLatLong
    }

}
