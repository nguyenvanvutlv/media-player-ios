//
//  HomeScreenView.swift
//  player
//
//  Created by nvv on 29/3/26.
//

import SwiftUI

struct HomeScreenView : View {
    var onSubmit: (URL) -> Void = { _ in }
    
    @State private var urlText: String = "https://dl-a10b-1542.mypikpak.com/download/?fid=2_5pmY3pb30KFMdtz4jM0xLyVJbvLWXMM85nJ8FopW5sh8zR588OjTNY5bdUjtegqq5BS0aeCZyNrf5ogShgPGDoZzT-vUu_tJ2oJhKlEDU=&from=5&verno=3&prod=pikpak&expire=1775056206&g=5E0850D616A18C646F060BF580B6C933DFC84782&ui=aJgD4HNLZR8dbfo1&t=0&ms=81600000&th=81600000&f=1661725618&alt=0&us=0&hspu=&po=0&userid=aJgD4HNLZR8dbfo1&fileid=VOnXnmMfMpe2wiXeu2hUrNCSo2&pr=XQPkPvr9WWiIuMvELmrVemzS3dNokdyW-NYmmbFU2np-HKPfvum_gW6CCVQ0soCjMxEl6WQuy5SrDceb3ny5phru1j5NHs9ozOVy9L-PUhdbDo4Sbfed6FmOq2T7n8OGVC5oK9M6BugiQb885Rd5yh6v00lHSkjRpldMOUqNO31Eii4wy9hkZJ9C8h2auy9kI1C_zXKPlyTc4xzDVBiKWy78WhPHTh6XLmFJ2_vPk2GCVrCjEZZ24q4B3uGorBmSyy35Z2mhaoz-EJPjsX9PDpkocYxHHNe4oYUwSyRC78923Lz-1AvMCtEqfDzg3wA-LaOX2-Lt-_oQxeybD54qXEv0Y4nF-cRkRGSKXeVMO_ZUsv4ebpXD5NyLGgAy_ilwrWVUBLuV6Urfmk7Hn_t64JtVIZnnW9cAvhoGfD7Cvkqw5WVIKM21Qpsy2TPPi6IE&sign=279C5DBB8CB8308872635DD134F36A90"
    @State private var showInvalidURLAlert: Bool = false
    
    var body: some View {
        ZStack {
            AppTheme.Gradient.primaryBackground
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
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
                
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source URL")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                            
                            TextField("", text: $urlText)
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
