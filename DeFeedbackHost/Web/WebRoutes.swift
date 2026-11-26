//
//  WebRoutes.swift
//  DeFeedbackHost
//
//  The web API's route table: which path answers which methods, and what a wrong method is told.
//  Every path here must be documented in openapi.yaml and vice versa (OpenAPIConformanceTests
//  reads this file to check). One path, `/api/instances/{id}`, is matched by template first.
//  Replaces the long `switch` that lived in WebControlService (issue #41); behaviour is unchanged.
//
import Foundation

enum WebRoutes {

    /// Handles a request: the service, the request, and the `{id}` of the instance template (else nil).
    typealias Handler = @MainActor @Sendable (WebControlService, HTTPRequest, String?) async -> HTTPServer.RouteOutcome

    struct Route {
        let handlers: [String: Handler]

        /// What a method that has no handler is told (405) and which methods the `Allow` header lists.
        let wrongMethod: WebErrorStrings
        let allow: String

        @MainActor
        func answer(_ request: HTTPRequest, from service: WebControlService, id: String?) async -> HTTPServer.RouteOutcome {
            guard let handler = handlers[request.method] else {
                return .respond(.error(405, wrongMethod.rawValue, headers: [("Allow", allow)]))
            }
            return await handler(service, request, id)
        }
    }

    /// The one route matched by template rather than whole path. Checked before `table`.
    static let instanceTemplate = "/api/instances/{id}"

    static let instance = Route(
        handlers: ["GET": showInstance, "HEAD": showInstance, "PATCH": patchInstance, "DELETE": deleteInstance],
        wrongMethod: .UseInstanceMethod, allow: "GET, HEAD, PATCH, DELETE")

    /// Whole-path routes. A path that is not here is a 404.
    static let table: [String: Route] = [
        "/": Route(handlers: ["GET": page, "HEAD": page], wrongMethod: .UseGET, allow: "GET, HEAD"),
        // HEAD is listed in `Allow` but not served here; kept as it was (see implementation-notes.md).
        "/index.html": Route(handlers: ["GET": page], wrongMethod: .UseGET, allow: "GET, HEAD"),
        "/api/status": Route(handlers: ["GET": status, "HEAD": status], wrongMethod: .UseGET, allow: "GET, HEAD"),
        "/api/update": Route(handlers: ["GET": update, "HEAD": update], wrongMethod: .UseGET, allow: "GET, HEAD"),
        "/api/instances": Route(handlers: ["GET": list, "HEAD": list, "POST": addInstance],
                                wrongMethod: .UseGETorPOST, allow: "GET, HEAD, POST"),
        "/api/events": Route(handlers: ["GET": events], wrongMethod: .UseGET, allow: "GET"),
        "/api/system": Route(handlers: ["POST": system], wrongMethod: .UsePOST, allow: "POST"),
        "/api/devices": Route(handlers: ["POST": devices], wrongMethod: .UsePOST, allow: "POST"),
        "/api/sample-rate": Route(handlers: ["POST": sampleRate], wrongMethod: .UsePOST, allow: "POST"),
        "/api/buffer-size": Route(handlers: ["POST": bufferSize], wrongMethod: .UsePOST, allow: "POST")
    ]

    // MARK: - Handlers

    private static func page(_ service: WebControlService, _ request: HTTPRequest,
                             _ id: String?) -> HTTPServer.RouteOutcome {
        .respond(service.pageResponse())
    }

    private static func status(_ service: WebControlService, _ request: HTTPRequest,
                               _ id: String?) -> HTTPServer.RouteOutcome {
        .respond(.json(service.statusPayload()))
    }

    private static func update(_ service: WebControlService, _ request: HTTPRequest,
                               _ id: String?) -> HTTPServer.RouteOutcome {
        .respond(.json(service.updatePayload()))
    }

    private static func list(_ service: WebControlService, _ request: HTTPRequest,
                             _ id: String?) -> HTTPServer.RouteOutcome {
        .respond(.json(WebStatusPayload.instanceList(service.host.instances)))
    }

    private static func events(_ service: WebControlService, _ request: HTTPRequest,
                               _ id: String?) -> HTTPServer.RouteOutcome {
        .stream(EventStream.preamble) { [weak service] stream in
            guard let service else { return }
            Task { @MainActor in
                service.attachStream(stream)
            }
        }
    }

    private static func system(_ service: WebControlService, _ request: HTTPRequest,
                               _ id: String?) async -> HTTPServer.RouteOutcome {
        .respond(await service.controlSystem(request))
    }

    private static func devices(_ service: WebControlService, _ request: HTTPRequest,
                                _ id: String?) async -> HTTPServer.RouteOutcome {
        .respond(await service.setDevices(request))
    }

    private static func sampleRate(_ service: WebControlService, _ request: HTTPRequest,
                                   _ id: String?) async -> HTTPServer.RouteOutcome {
        .respond(await service.setSampleRate(request))
    }

    private static func bufferSize(_ service: WebControlService, _ request: HTTPRequest,
                                   _ id: String?) async -> HTTPServer.RouteOutcome {
        .respond(await service.setBufferSize(request))
    }

    private static func addInstance(_ service: WebControlService, _ request: HTTPRequest,
                                    _ id: String?) async -> HTTPServer.RouteOutcome {
        .respond(await service.addInstance(request))
    }

    private static func showInstance(_ service: WebControlService, _ request: HTTPRequest,
                                     _ id: String?) -> HTTPServer.RouteOutcome {
        .respond(service.instanceResponse(id: id ?? ""))
    }

    private static func patchInstance(_ service: WebControlService, _ request: HTTPRequest,
                                      _ id: String?) async -> HTTPServer.RouteOutcome {
        .respond(await service.updateInstance(id: id ?? "", request))
    }

    private static func deleteInstance(_ service: WebControlService, _ request: HTTPRequest,
                                       _ id: String?) -> HTTPServer.RouteOutcome {
        .respond(service.removeInstance(id: id ?? ""))
    }
}
