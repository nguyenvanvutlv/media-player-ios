//
//  HomeScreenView.swift
//  player
//
//  Created by nvv on 29/3/26.
//

import SwiftUI

struct HomeScreenView : View {
    var onSubmit: (URL) -> Void = { _ in }
    
    @State private var urlText: String = ""
    @State private var showInvalidURLAlert: Bool = false
    
    var body: some View {
        ZStack {
            AppTheme.Gradient.primaryBackground
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Media Player")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    Text("Enter a streaming URL to start playback.")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                
                // URL Input Card
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source URL")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                            
                            TextField("https://example.com/video.m3u8", text: $urlText)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .foregroundStyle(.white)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .onSubmit {
                                    submitIfPossible()
                                }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                    
                    // Helper text
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Supports HLS, MP4, MKV and other popular formats.")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer(minLength: 0)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            AppTheme.Surface.elevated
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Play button + secondary actions
                VStack(spacing: 16) {
                    Button(action: {
                        submitIfPossible()
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                            
                            Text("Submit & Play")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            AppTheme.Gradient.accentButton
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 16)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 20)
            }
        }
        .alert("Invalid URL", isPresented: $showInvalidURLAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please enter a valid URL (including http:// or https://).")
        }
    }
    
    private func submitIfPossible() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            showInvalidURLAlert = true
            return
        }
        onSubmit(url)
    }
}
